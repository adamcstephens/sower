defmodule Sower.GardenAuth do
  use TypedStruct

  require Logger

  alias Boruta.ClientsAdapter
  alias Boruta.Oauth.Authorization
  alias Boruta.Oauth.Client
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.Request
  alias Boruta.Oauth.TokenResponse

  @access_token_ttl 900

  typedstruct module: Context do
    field :org_id, String.t(), enforce: true
    field :garden_id, integer(), enforce: true
    field :scope, String.t(), enforce: true
  end

  def create_client(garden_name, public_key_pem) do
    Boruta.Ecto.Admin.create_client(%{
      name: "garden:#{garden_name}",
      redirect_uris: ["https://localhost"],
      supported_grant_types: ["client_credentials"],
      access_token_ttl: @access_token_ttl,
      authorize_scope: true,
      authorized_scopes: [%{name: "garden:agent"}],
      confidential: true,
      jwt_public_key: public_key_pem,
      token_endpoint_auth_methods: ["private_key_jwt"],
      token_endpoint_jwt_auth_alg: "RS512"
    })
  end

  def delete_client(oauth_client_id) do
    client = Boruta.Ecto.Admin.get_client!(oauth_client_id)
    Boruta.Ecto.Admin.delete_client(client)
  end

  def issue(client_assertion) do
    case token_request(%{
           "grant_type" => "client_credentials",
           "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
           "client_assertion" => client_assertion,
           "scope" => "garden:agent"
         }) do
      {:ok, token_response} ->
        {:ok, token_response}

      {:error, %Error{error: :invalid_client}} ->
        {:error, classify_invalid_client(client_assertion)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp classify_invalid_client(client_assertion) do
    {:ok, claims} = Joken.peek_claims(client_assertion)

    reason =
      case ClientsAdapter.get_client(claims["sub"]) do
        %Client{} -> classify_claims(claims)
        nil -> :unknown_client
      end

    log_classification(reason, claims)

    reason
  end

  defp classify_claims(claims) do
    now = Joken.current_time()

    case claims["exp"] do
      exp when is_number(exp) and exp <= now -> {:assertion_expired, now - exp}
      _ -> :invalid_signature
    end
  end

  defp log_classification(reason, claims) do
    now = Joken.current_time()
    exp = claims["exp"]
    iat = claims["iat"]

    Logger.warning(
      msg: "Client assertion rejected",
      classification: classification_name(reason),
      client_id: to_string(claims["sub"]),
      exp_skew_seconds: skew_field(now, exp),
      iat_skew_seconds: skew_field(now, iat)
    )
  end

  defp skew_field(now, value) when is_number(value), do: to_string(now - value)
  defp skew_field(_now, _value), do: "unknown"

  defp classification_name({:assertion_expired, _skew}), do: "assertion_expired"
  defp classification_name(reason), do: to_string(reason)

  defp token_request(body_params) do
    request = %{body_params: body_params, req_headers: []}

    with {:ok, token_request} <- Request.token_request(request),
         {:ok, tokens} <- Authorization.token(token_request),
         %TokenResponse{} = response <- TokenResponse.from_token(tokens) do
      {:ok,
       %{
         access_token: response.access_token,
         expires_in: response.expires_in,
         token_type: response.token_type
       }}
    else
      {:error, %Error{} = error} ->
        Logger.error(
          msg: "OAuth token request failed",
          error: error.error,
          error_description: error.error_description
        )

        {:error, error}

      {:error, reason} ->
        Logger.error(msg: "OAuth token request failed", error: inspect(reason))
        {:error, reason}
    end
  end
end
