defmodule SowerWeb.OAuth.TokenControllerTest do
  use SowerWeb.ConnCase, async: false

  alias Sower.GardenAuth

  defp generate_keypair do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_, priv} = JOSE.JWK.to_pem(jwk)
    {_, pub} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {priv, pub}
  end

  defp build_assertion(client_id, private_key_pem, claim_overrides \\ %{}) do
    now = System.system_time(:second)

    claims =
      Map.merge(
        %{
          "iss" => client_id,
          "sub" => client_id,
          "aud" => "sower",
          "iat" => now,
          "exp" => now + 60
        },
        claim_overrides
      )

    jwk = JOSE.JWK.from_pem(private_key_pem)
    {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, %{"alg" => "RS512"}, claims))
    token
  end

  defp post_assertion(conn, assertion) do
    post(conn, ~p"/api/oauth/token", %{
      "grant_type" => "client_credentials",
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion" => assertion
    })
  end

  setup do
    {private_pem, public_pem} = generate_keypair()
    {:ok, client} = GardenAuth.create_client("grdn_test", public_pem)

    %{client: client, private_pem: private_pem}
  end

  test "returns a token for a valid assertion", %{
    conn: conn,
    client: client,
    private_pem: private_pem
  } do
    conn = post_assertion(conn, build_assertion(client.id, private_pem))

    assert %{"access_token" => access_token} = json_response(conn, 200)
    assert is_binary(access_token)
  end

  test "distinguishes an expired assertion", %{
    conn: conn,
    client: client,
    private_pem: private_pem
  } do
    now = System.system_time(:second)
    assertion = build_assertion(client.id, private_pem, %{"exp" => now - 90})

    conn = post_assertion(conn, assertion)

    assert %{"error" => "invalid_client", "error_reason" => "assertion_expired"} =
             json_response(conn, 400)
  end

  test "distinguishes a bad signature", %{conn: conn, client: client} do
    {other_private_pem, _} = generate_keypair()
    conn = post_assertion(conn, build_assertion(client.id, other_private_pem))

    assert %{"error" => "invalid_client", "error_reason" => "invalid_signature"} =
             json_response(conn, 400)
  end

  test "distinguishes an unknown client", %{conn: conn, private_pem: private_pem} do
    conn = post_assertion(conn, build_assertion(Ecto.UUID.generate(), private_pem))

    assert %{"error" => "invalid_client", "error_reason" => "unknown_client"} =
             json_response(conn, 400)
  end

  test "rejects an unsupported grant type", %{conn: conn} do
    conn = post(conn, ~p"/api/oauth/token", %{"grant_type" => "password"})

    assert %{"error" => "unsupported_grant_type"} = json_response(conn, 400)
  end
end
