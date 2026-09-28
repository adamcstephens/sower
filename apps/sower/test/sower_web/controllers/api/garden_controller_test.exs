defmodule SowerWeb.Api.GardenControllerTest do
  use SowerWeb.ConnCase, async: true

  alias Sower.AccountsFixtures
  alias Sower.Orchestration.{Deployment, DeploymentEvent}
  alias Sower.Repo

  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture()

    {:ok, access_token} =
      Sower.Accounts.AccessToken.create(%{
        "description" => "test",
        "user_id" => user.id,
        "org_id" => user.org_id,
        "permissions" => [%{"role" => "garden:register"}]
      })

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{access_token.token}")
      |> put_req_header("content-type", "application/json")

    {_private_pem, public_pem} =
      JOSE.JWK.generate_key({:rsa, 2048})
      |> then(fn jwk ->
        {_, priv} = JOSE.JWK.to_pem(jwk)
        {_, pub} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
        {priv, pub}
      end)

    %{conn: conn, user: user, public_pem: public_pem}
  end

  describe "POST /api/v1/gardens/register" do
    test "registers a new garden and returns sid + oauth credentials", %{
      conn: conn,
      public_pem: public_pem
    } do
      conn =
        post(conn, ~p"/api/v1/gardens/register", %{
          "name" => "test-garden",
          "public_key" => public_pem
        })

      assert %{"sid" => sid, "oauth_credentials" => %{"client_id" => client_id}} =
               json_response(conn, 201)

      assert is_binary(sid)
      assert is_binary(client_id)
    end

    test "returns 401 when token lacks garden:register permission", %{
      conn: conn,
      public_pem: public_pem
    } do
      user = AccountsFixtures.user_fixture()

      {:ok, read_only_token} =
        Sower.Accounts.AccessToken.create(%{
          "description" => "read only",
          "user_id" => user.id,
          "org_id" => user.org_id,
          "permissions" => [%{"role" => "seed:read"}]
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{read_only_token.token}")
        |> post(~p"/api/v1/gardens/register", %{
          "name" => "test-garden",
          "public_key" => public_pem
        })

      assert json_response(conn, 401) == %{"error" => "unauthorized"}
    end

    test "returns 422 when required fields are missing", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/gardens/register", %{})

      assert conn.status == 422
    end
  end

  describe "GET /api/v1/gardens/:garden/latest-seed" do
    setup %{conn: conn, user: user} do
      Repo.put_org_id(user.org_id)
      garden = garden_fixture(%{name: "warm-garden", org_id: user.org_id})

      %{
        garden: garden,
        read_conn: put_req_header(conn, "authorization", "Bearer #{token_for(user, "seed:read")}")
      }
    end

    test "selects the oldest matching subscription then its latest rule-matching seed", %{
      read_conn: conn,
      garden: garden,
      user: user
    } do
      other_garden = garden_fixture(%{org_id: user.org_id})

      subscription_fixture(%{
        garden_id: other_garden.id,
        name: "elsewhere",
        seed_name: "host",
        seed_type: "nixos"
      })

      subscription_fixture(%{
        garden_id: garden.id,
        name: "first",
        seed_name: "host",
        seed_type: "nixos",
        rules: [%{key: "branch", op: "eq", value: "stable"}]
      })

      subscription_fixture(%{
        garden_id: garden.id,
        name: "second",
        seed_name: "host",
        seed_type: "nixos",
        rules: [%{key: "branch", op: "eq", value: "edge"}]
      })

      seed_fixture(%{
        name: "host",
        seed_type: "nixos",
        tags: [%{key: "branch", value: "stable"}]
      })

      selected =
        seed_fixture(%{
          name: "host",
          seed_type: "nixos",
          tags: [%{key: "branch", value: "stable"}]
        })

      seed_fixture(%{name: "host", seed_type: "nixos", tags: [%{key: "branch", value: "edge"}]})

      conn = get(conn, ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host&seed_type=nixos")
      assert %{"sid" => sid, "artifact" => artifact} = json_response(conn, 200)
      assert sid == selected.sid
      assert artifact == selected.artifact
      assert Repo.aggregate(Deployment, :count) == 0
      assert Repo.aggregate(DeploymentEvent, :count) == 0
    end

    test "resolves a unique garden name and returns 204 for missing seed or subscription", %{
      read_conn: conn,
      garden: garden
    } do
      subscription_fixture(%{
        garden_id: garden.id,
        name: "host",
        seed_name: "host",
        seed_type: "nixos",
        rules: [%{key: "branch", op: "eq", value: "stable"}]
      })

      subscription_fixture(%{
        garden_id: garden.id,
        name: "newer",
        seed_name: "host",
        seed_type: "nixos",
        rules: [%{key: "branch", op: "eq", value: "edge"}]
      })

      seed_fixture(%{name: "host", seed_type: "nixos", tags: [%{key: "branch", value: "edge"}]})

      assert get(
               conn,
               ~p"/api/v1/gardens/#{garden.name}/latest-seed?name=host&seed_type=nixos"
             ).status == 204

      assert get(
               conn,
               ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=absent&seed_type=nixos"
             ).status == 204

      assert get(
               conn,
               ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host&seed_type=home-manager"
             ).status == 204
    end

    test "returns garden resolution errors and rejects unauthorized access", %{
      conn: conn,
      read_conn: read_conn,
      garden: garden,
      user: user
    } do
      garden_fixture(%{name: garden.name, org_id: user.org_id})

      assert json_response(
               get(
                 read_conn,
                 ~p"/api/v1/gardens/#{garden.name}/latest-seed?name=host&seed_type=nixos"
               ),
               409
             )["error"]

      assert json_response(
               get(
                 read_conn,
                 ~p"/api/v1/gardens/grdn_missing/latest-seed?name=host&seed_type=nixos"
               ),
               404
             )["error"]

      assert json_response(
               get(conn, ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host&seed_type=nixos"),
               401
             )["error"]

      denied_conn =
        conn
        |> put_req_header("authorization", "Bearer #{token_for(user, "deployment:read")}")
        |> get(~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host&seed_type=nixos")

      assert json_response(denied_conn, 401)["error"] == "unauthorized"
    end

    test "requires name and seed type and does not expose another organization's garden", %{
      read_conn: conn,
      garden: garden
    } do
      assert get(conn, ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host").status == 422

      other_user = AccountsFixtures.user_fixture()

      other_conn =
        conn
        |> put_req_header("authorization", "Bearer #{token_for(other_user, "seed:read")}")
        |> get(~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host&seed_type=nixos")

      assert json_response(other_conn, 404)["error"] == "garden_not_found"
    end

    test "never returns seeds from another organization", %{
      read_conn: conn,
      garden: garden,
      user: user
    } do
      subscription_fixture(%{
        garden_id: garden.id,
        name: "host",
        seed_name: "host",
        seed_type: "nixos"
      })

      own_seed = seed_fixture(%{name: "host", seed_type: "nixos"})

      subscription_fixture(%{
        garden_id: garden.id,
        name: "foreign-only",
        seed_name: "foreign-only",
        seed_type: "nixos"
      })

      _other_user = AccountsFixtures.user_fixture()
      seed_fixture(%{name: "host", seed_type: "nixos"})
      seed_fixture(%{name: "foreign-only", seed_type: "nixos"})
      Repo.put_org_id(user.org_id)

      assert json_response(
               get(conn, ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=host&seed_type=nixos"),
               200
             )["sid"] == own_seed.sid

      assert get(
               conn,
               ~p"/api/v1/gardens/#{garden.sid}/latest-seed?name=foreign-only&seed_type=nixos"
             ).status == 204
    end
  end

  defp token_for(user, role) do
    {:ok, token} =
      Sower.Accounts.AccessToken.create(%{
        "description" => role,
        "user_id" => user.id,
        "org_id" => user.org_id,
        "permissions" => [%{"role" => role}]
      })

    token.token
  end
end
