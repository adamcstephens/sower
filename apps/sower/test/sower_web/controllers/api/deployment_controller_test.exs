defmodule SowerWeb.Api.DeploymentControllerTest do
  use SowerWeb.ConnCase, async: true

  alias Sower.Orchestration.Garden

  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  @direct_policy [%{name: "direct", actions: ["activate"], triggers: ["direct"]}]

  setup %{conn: conn} do
    user = Sower.AccountsFixtures.user_fixture()
    Sower.Repo.put_org_id(user.org_id)

    garden = garden_fixture(%{org_id: user.org_id, name: "api-garden"})
    seed = seed_fixture(%{org_id: user.org_id, name: "api-host", seed_type: "nixos"})

    %{
      conn: put_req_header(conn, "content-type", "application/json"),
      user: user,
      garden: garden,
      seed: seed
    }
  end

  defp token(user, roles) do
    {:ok, access_token} =
      Sower.Accounts.AccessToken.create(%{
        "description" => "test",
        "user_id" => user.id,
        "org_id" => user.org_id,
        "permissions" => Enum.map(roles, &%{"role" => &1})
      })

    access_token.token
  end

  defp authed(conn, user, roles) do
    put_req_header(conn, "authorization", "Bearer #{token(user, roles)}")
  end

  defp allow_direct(%Garden{} = garden) do
    {:ok, garden} = Garden.update_garden(garden, %{policy: @direct_policy})
    garden
  end

  describe "POST /api/v1/deployments" do
    test "deploys by garden sid", %{conn: conn, user: user, garden: garden, seed: seed} do
      allow_direct(garden)

      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.sid, "seed" => seed.sid})

      assert %{"sid" => sid, "garden_sid" => garden_sid, "seeds" => [seed_info]} =
               json_response(conn, 201)

      assert is_binary(sid)
      assert garden_sid == garden.sid
      assert seed_info["seed_sid"] == seed.sid
    end

    test "deploys by garden name", %{conn: conn, user: user, garden: garden, seed: seed} do
      allow_direct(garden)

      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.name, "seed" => seed.sid})

      assert %{"garden_sid" => garden_sid} = json_response(conn, 201)
      assert garden_sid == garden.sid
    end

    test "409 when the garden name is ambiguous", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      allow_direct(garden)
      garden_fixture(%{org_id: user.org_id, name: garden.name})

      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.name, "seed" => seed.sid})

      assert %{"error" => _} = json_response(conn, 409)
    end

    test "404 for an unknown garden", %{conn: conn, user: user, seed: seed} do
      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => "grdn_nope", "seed" => seed.sid})

      assert json_response(conn, 404)
    end

    test "404 for an unknown seed", %{conn: conn, user: user, garden: garden} do
      allow_direct(garden)

      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.sid, "seed" => "seed_nope"})

      assert json_response(conn, 404)
    end

    test "403 when the garden policy denies direct", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.sid, "seed" => seed.sid})

      assert %{"error" => "policy_denied"} = json_response(conn, 403)
    end

    test "401 without deployment:write", %{conn: conn, user: user, garden: garden, seed: seed} do
      allow_direct(garden)

      conn =
        conn
        |> authed(user, ["seed:read"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.sid, "seed" => seed.sid})

      assert json_response(conn, 401)
    end

    test "401 overriding without deployment:override", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      conn =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{
          "garden" => garden.sid,
          "seed" => seed.sid,
          "override" => true,
          "action" => "activate",
          "reason" => "break glass"
        })

      assert json_response(conn, 401)
    end

    test "overrides policy with the override scope", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      conn =
        conn
        |> authed(user, ["deployment:write", "deployment:override"])
        |> post(~p"/api/v1/deployments", %{
          "garden" => garden.sid,
          "seed" => seed.sid,
          "override" => true,
          "action" => "restart",
          "reason" => "break glass"
        })

      assert %{"sid" => _} = json_response(conn, 201)
    end

    test "422 when overriding without a reason", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      conn =
        conn
        |> authed(user, ["deployment:write", "deployment:override"])
        |> post(~p"/api/v1/deployments", %{
          "garden" => garden.sid,
          "seed" => seed.sid,
          "override" => true,
          "action" => "restart"
        })

      assert %{"error" => "override_reason_required"} = json_response(conn, 422)
    end

    test "422 when overriding without an action", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      conn =
        conn
        |> authed(user, ["deployment:write", "deployment:override"])
        |> post(~p"/api/v1/deployments", %{
          "garden" => garden.sid,
          "seed" => seed.sid,
          "override" => true,
          "reason" => "break glass"
        })

      assert %{"error" => "override_action_required"} = json_response(conn, 422)
    end
  end

  describe "GET /api/v1/deployments/:sid" do
    test "returns deployment state for polling", %{
      conn: conn,
      user: user,
      garden: garden,
      seed: seed
    } do
      allow_direct(garden)

      created =
        conn
        |> authed(user, ["deployment:write"])
        |> post(~p"/api/v1/deployments", %{"garden" => garden.sid, "seed" => seed.sid})
        |> json_response(201)

      conn =
        conn
        |> authed(user, ["deployment:read"])
        |> get(~p"/api/v1/deployments/#{created["sid"]}")

      assert %{"sid" => sid, "state" => "dispatched", "seeds" => [_]} = json_response(conn, 200)
      assert sid == created["sid"]
    end

    test "401 without deployment:read", %{conn: conn, user: user} do
      conn =
        conn
        |> authed(user, ["seed:read"])
        |> get(~p"/api/v1/deployments/dply_nope")

      assert json_response(conn, 401)
    end

    test "404 for an unknown deployment", %{conn: conn, user: user} do
      conn =
        conn
        |> authed(user, ["deployment:read"])
        |> get(~p"/api/v1/deployments/dply_nope")

      assert json_response(conn, 404)
    end
  end
end
