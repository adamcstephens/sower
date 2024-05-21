defmodule Sower.Accounts.Secrets do
  use AshAuthentication.Secret

  def secret_for([:authentication, :tokens, :signing_secret], Sower.Accounts.User, _) do
    case Application.fetch_env(:example, ExampleWeb.Endpoint) do
      {:ok, endpoint_config} ->
        Keyword.fetch(endpoint_config, :secret_key_base)

      :error ->
        :error
    end
  end

  def secret_for([:authentication, :strategies, :oidc, :client_id], Sower.Accounts.User, _) do
    Application.fetch_env(:sower, :oidc_client_id)
  end

  def secret_for([:authentication, :strategies, :oidc, :client_secret], Sower.Accounts.User, _) do
    Application.fetch_env(:sower, :oidc_client_secret)
  end
end
