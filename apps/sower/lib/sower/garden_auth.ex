defmodule Sower.GardenAuth do
  use TypedStruct

  require Logger

  alias Boruta.Oauth.Authorization
  alias Boruta.Oauth.Error
  alias Boruta.Oauth.Request
  alias Boruta.Oauth.TokenResponse

  @access_token_ttl 900
  @refresh_token_ttl 2_592_000

  typedstruct module: Context do
    field :org_id, String.t(), enforce: true
    field :garden_id, integer(), enforce: true
    field :scope, String.t(), enforce: true
  end

  def create_client(garden_name) do
    Boruta.Ecto.Admin.create_client(%{
      name: "garden:#{garden_name}",
      redirect_uris: ["https://localhost"],
      supported_grant_types: ["client_credentials", "refresh_token"],
      access_token_ttl: @access_token_ttl,
      refresh_token_ttl: @refresh_token_ttl,
      authorize_scope: true,
      authorized_scopes: [%{name: "garden:agent"}],
      confidential: true
    })
  end

  def delete_client(boruta_client_id) do
    client = Boruta.Ecto.Admin.get_client!(boruta_client_id)
    Boruta.Ecto.Admin.delete_client(client)
  end

  def issue(client_id, client_secret) do
    token_request(%{
      "grant_type" => "client_credentials",
      "client_id" => client_id,
      "client_secret" => client_secret,
      "scope" => "garden:agent"
    })
  end

  def refresh(refresh_token_value) do
    token_request(%{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token_value
    })
  end

  defp token_request(body_params) do
    request = %{body_params: body_params, req_headers: []}

    with {:ok, token_request} <- Request.token_request(request),
         {:ok, tokens} <- Authorization.token(token_request),
         %TokenResponse{} = response <- TokenResponse.from_token(tokens) do
      {:ok,
       %{
         access_token: response.access_token,
         refresh_token: response.refresh_token,
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
