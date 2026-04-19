defmodule Garden.Auth do
  require Logger

  @jws_alg "RS512"
  @key_size 4096
  @assertion_ttl_seconds 30

  def generate_keypair do
    jwk = JOSE.JWK.generate_key({:rsa, @key_size})
    {_, private_pem} = JOSE.JWK.to_pem(jwk)
    {_, public_pem} = jwk |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    {private_pem, public_pem}
  end

  def public_key_from_private(private_key_pem) do
    {_, public_pem} =
      private_key_pem
      |> JOSE.JWK.from_pem()
      |> JOSE.JWK.to_public()
      |> JOSE.JWK.to_pem()

    public_pem
  end

  def ensure_keypair(%{private_key_pem: pem} = storage) when is_binary(pem) do
    {public_key_from_private(pem), storage}
  end

  def ensure_keypair(%{} = storage) do
    {private_pem, public_pem} = generate_keypair()
    storage = Map.put(storage, :private_key_pem, private_pem)
    Garden.Storage.write(storage)
    Logger.info(msg: "Generated new RSA keypair for garden authentication")
    {public_pem, storage}
  end

  def build_assertion(client_id, private_key_pem) do
    now = System.system_time(:second)

    claims = %{
      "iss" => client_id,
      "sub" => client_id,
      "aud" => "sower",
      "iat" => now,
      "exp" => now + @assertion_ttl_seconds
    }

    jwk = JOSE.JWK.from_pem(private_key_pem)
    jws = %{"alg" => @jws_alg}
    {_, token} = JOSE.JWS.compact(JOSE.JWT.sign(jwk, jws, claims))
    token
  end

  def request_token(client_id, private_key_pem, post_fun \\ &Req.post/2) do
    endpoint = Garden.Config.get().endpoint
    assertion = build_assertion(client_id, private_key_pem)

    case post_fun.("#{endpoint}/api/oauth/token",
           json: %{
             grant_type: "client_credentials",
             client_assertion_type: "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
             client_assertion: assertion,
             scope: "garden:agent"
           }
         ) do
      {:ok, %{status: 200, body: body}} ->
        {:ok,
         %{
           access_token: body["access_token"],
           expires_in: body["expires_in"],
           token_type: body["token_type"]
         }}

      {:ok, %{status: status, body: body}} when status >= 400 and status < 500 ->
        Logger.warning(
          msg: "Token request rejected by server",
          status: to_string(status),
          error: inspect(body)
        )

        {:error, {:server_rejected, status}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning(
          msg: "Token request server error",
          status: to_string(status),
          error: inspect(body)
        )

        {:error, {:server_error, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        Logger.warning(msg: "Token request transport error", reason: inspect(reason))
        {:error, {:transport_error, reason}}

      {:error, error} ->
        Logger.warning(msg: "Token request error", error: inspect(error))
        {:error, {:request_error, error}}
    end
  end
end
