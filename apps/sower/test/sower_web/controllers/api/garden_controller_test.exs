defmodule SowerWeb.Api.GardenControllerTest do
  use SowerWeb.ConnCase, async: true

  alias Sower.AccountsFixtures

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
end
