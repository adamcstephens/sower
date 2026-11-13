defmodule SowerWeb.Api.ProfileControllerTest do
  use SowerWeb.ConnCase, async: true
  import Sower.OrchestrationFixtures
  alias Sower.Orchestration.{ManagedProfile, Subscription}
  alias Sower.Repo

  setup %{conn: conn} do
    user = Sower.AccountsFixtures.user_fixture()
    Repo.put_org_id(user.org_id)
    garden = garden_fixture(%{capabilities: ["managed_profiles_v1"]})

    {:ok, token} =
      Sower.Accounts.AccessToken.create(%{
        "description" => "profiles",
        "user_id" => user.id,
        "org_id" => user.org_id,
        "permissions" => [%{"role" => "deployment:write"}]
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token.token}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, garden: garden, user: user}
  end

  test "operator create, retention update and offline delete expose durable outcomes", %{
    conn: conn,
    garden: garden
  } do
    base = "/api/v1/gardens/#{garden.sid}"

    created =
      post(conn, base <> "/subscriptions", %{
        "name" => "tools",
        "seed_name" => "tools",
        "seed_type" => "package",
        "retention" => %{"keep_generations" => 2},
        "origin" => "declared"
      })

    assert %{"sid" => sid, "origin" => "operator", "retention" => %{"keep_generations" => 2}} =
             json_response(created, 200)

    updated = patch(conn, base <> "/subscriptions/#{sid}", %{"retention" => nil})
    assert %{"retention" => nil} = json_response(updated, 200)
    removed = delete(conn, base <> "/subscriptions/#{sid}")

    assert %{"status" => "pending", "request_id" => request_id, "warning" => warning} =
             json_response(removed, 202)

    assert warning =~ "External services"
    assert Subscription.get_subscription_sid!(sid).uninstall_pending
    status = get(conn, base <> "/profiles/operations/#{request_id}")
    assert %{"status" => "pending"} = json_response(status, 200)

    assert [%{name: "tools", lifecycle_status: "uninstall_pending"}] =
             ManagedProfile.list_for_garden(garden)
  end

  test "full subscription response roundtrips when retention and embedded policies change", %{
    conn: conn,
    garden: garden
  } do
    base = "/api/v1/gardens/#{garden.sid}/subscriptions"

    subscription =
      conn
      |> post(base, %{
        "name" => "shell",
        "seed_name" => "devshell-fixture",
        "seed_type" => "devshell",
        "rules" => [%{"key" => "branch", "op" => "eq", "value" => "main"}],
        "policy" => %{
          "manual" => %{
            "actions" => ["stage", "activate"],
            "triggers" => ["manual"],
            "confirm" => false,
            "window" => nil
          }
        }
      })
      |> json_response(200)

    endpoint = base <> "/" <> subscription["sid"]
    retention = %{"keep_generations" => 1, "keep_days" => 1}
    body = subscription |> Map.delete("sid") |> Map.put("retention", retention)
    updated = conn |> patch(endpoint, body) |> json_response(200)
    assert updated["retention"] == retention
    assert updated["policy"] == subscription["policy"]
    assert updated["rules"] == subscription["rules"]

    replacement =
      updated
      |> Map.delete("sid")
      |> Map.put("rules", [])
      |> Map.put("policy", %{"staging" => %{"actions" => ["stage"], "triggers" => ["manual"]}})

    replaced = conn |> patch(endpoint, replacement) |> json_response(200)
    assert replaced["rules"] == []
    assert Map.keys(replaced["policy"]) == ["staging"]
    assert replaced["policy"]["staging"]["actions"] == ["stage"]
  end

  test "read-only token cannot mutate profiles", %{conn: conn, user: user, garden: garden} do
    {:ok, token} =
      Sower.Accounts.AccessToken.create(%{
        "description" => "read",
        "user_id" => user.id,
        "org_id" => user.org_id,
        "permissions" => [%{"role" => "deployment:read"}]
      })

    conn = put_req_header(conn, "authorization", "Bearer #{token.token}")

    response =
      post(conn, "/api/v1/gardens/#{garden.sid}/profiles/operations", %{
        "request_id" => "denied",
        "profile_name" => "tools",
        "action" => "uninstall"
      })

    assert response.status == 401
    assert ManagedProfile.pending(garden) == []
  end

  test "operation lookup is scoped to requested garden", %{conn: conn, garden: garden} do
    assert {:ok, _} =
             Subscription.create_subscription(%{
               garden_id: garden.id,
               name: "tools",
               seed_name: "tools",
               seed_type: "package"
             })

    operation = %SowerClient.Orchestration.ProfileOperation{
      request_id: "one-garden",
      profile_name: "tools",
      action: "uninstall",
      preview: false
    }

    assert {:ok, _} = ManagedProfile.request(garden, operation)
    other = garden_fixture()
    response = get(conn, "/api/v1/gardens/#{other.sid}/profiles/operations/one-garden")
    assert response.status == 404
  end
end
