defmodule Sower.GardenAuthTest do
  use Sower.DataCase, async: false

  import ExUnit.CaptureLog

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

  setup do
    {private_pem, public_pem} = generate_keypair()
    {:ok, client} = GardenAuth.create_client("grdn_test", public_pem)

    %{client: client, private_pem: private_pem}
  end

  describe "issue/1" do
    test "issues a token for a valid assertion", %{client: client, private_pem: private_pem} do
      assertion = build_assertion(client.id, private_pem)

      assert {:ok, token} = GardenAuth.issue(assertion)
      assert is_binary(token.access_token)
    end

    test "reports an expired assertion with the observed skew", %{
      client: client,
      private_pem: private_pem
    } do
      now = System.system_time(:second)
      assertion = build_assertion(client.id, private_pem, %{"exp" => now - 90})

      assert {:error, {:assertion_expired, skew}} = GardenAuth.issue(assertion)
      assert skew >= 90
    end

    test "reports a signature mismatch when the assertion is signed with another key", %{
      client: client
    } do
      {other_private_pem, _} = generate_keypair()
      assertion = build_assertion(client.id, other_private_pem)

      assert {:error, :invalid_signature} = GardenAuth.issue(assertion)
    end

    test "reports an unknown client", %{private_pem: private_pem} do
      assertion = build_assertion(Ecto.UUID.generate(), private_pem)

      assert {:error, :unknown_client} = GardenAuth.issue(assertion)
    end

    test "logs the classification with the skew as a discrete field", %{
      client: client,
      private_pem: private_pem
    } do
      now = System.system_time(:second)
      assertion = build_assertion(client.id, private_pem, %{"exp" => now - 45})

      logs = capture_log(fn -> GardenAuth.issue(assertion) end)

      assert logs =~ "assertion_expired"
      assert logs =~ "exp_skew_seconds"
      assert logs =~ "iat_skew_seconds"
    end
  end
end
