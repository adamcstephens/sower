defmodule Forge.Foregejo do
  use OAuth2.Strategy

  # Public API

  def client do
    OAuth2.Client.new(
      strategy: __MODULE__,
      client_id: System.get_env("FORGEJO_CLIENT_ID"),
      client_secret: System.get_env("FORGEJO_CLIENT_SECRET"),
      redirect_uri: "http://localhost:4000/auth/callback",
      site: "https://git.junco.dev",
      authorize_url: "https://git.junco.dev/login/oauth/authorize",
      token_url: "https://git.junco.dev/login/oauth/access_token"
    )
    |> OAuth2.Client.put_serializer("application/json", Jason)
  end

  def authorize_url! do
    OAuth2.Client.authorize_url!(client(), scope: "read:user")
  end

  # you can pass options to the underlying http library via `opts` parameter
  def get_token!(params \\ [], headers \\ [], opts \\ []) do
    OAuth2.Client.get_token!(client(), params, headers, opts)
  end

  # Strategy Callbacks

  def authorize_url(client, params) do
    OAuth2.Strategy.AuthCode.authorize_url(client, params)
  end

  def get_token(client, params, headers) do
    client
    |> put_header("accept", "application/json")
    |> OAuth2.Strategy.AuthCode.get_token(params, headers)
  end
end
