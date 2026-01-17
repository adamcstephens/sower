defmodule SowerCli.Auth do
  @moduledoc """
  CLI authentication helpers.

  Provides early verification of server connection and token validity
  before expensive operations like eval/build.
  """

  alias SowerCli.{Config, Output}

  @doc """
  Verify server connection and token validity.

  Validates that:
  1. Endpoint and access_token are configured
  2. Token is valid and not expired (via API call)

  Returns :ok on success or {:error, reason} on failure.
  """
  def verify_connection() do
    config = Config.get()

    with :ok <- validate_config(config),
         :ok <- verify_token() do
      :ok
    end
  end

  defp validate_config(%SowerClient.Config{} = config) do
    try do
      Config.require_server_connection!(config)
      :ok
    rescue
      e in ArgumentError ->
        Output.error(e.message)
        {:error, :missing_server_config}
    end
  end

  defp verify_token() do
    case SowerClient.Auth.verify() do
      {:ok, %SowerClient.Auth.TokenInfo{} = token_info} ->
        Output.info("Authenticated: #{token_info.description}")
        :ok

      {:error, :unauthorized} ->
        Output.error("Authentication failed: invalid or expired token")
        {:error, :unauthorized}

      {:error, {:connection_error, reason}} ->
        Output.error("Connection failed: #{inspect(reason)}")
        {:error, {:connection_error, reason}}

      {:error, reason} ->
        Output.error("Authentication failed: #{inspect(reason)}")
        {:error, {:auth_failed, reason}}
    end
  end
end
