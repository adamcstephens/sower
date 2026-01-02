defmodule SowerCli.Config do
  @moduledoc """
  CLI configuration management.

  Delegates to `SowerClient.Config` for loading and validation.
  All fields are optional - CLI arguments can override config file values.
  """

  @app :sower_cli

  def load(overrides \\ %{}) do
    config =
      SowerClient.Config.load(
        overrides: overrides,
        config_path_env: "SOWER_CLI_CONFIG"
      )

    Application.put_env(@app, :config, config)
    config
  end

  def get do
    Application.get_env(@app, :config)
  end

  @doc """
  Validate that endpoint and access_token are present for server operations.

  Raises an error if either field is missing.
  """
  def require_server_connection!(%SowerClient.Config{} = config) do
    errors = []

    errors =
      if is_nil(config.endpoint) do
        ["endpoint is required (set via config file or --endpoint flag)" | errors]
      else
        errors
      end

    errors =
      if is_nil(config.access_token) do
        ["access_token is required (set via config file or access_token_file)" | errors]
      else
        errors
      end

    case errors do
      [] ->
        :ok

      _ ->
        raise ArgumentError, Enum.join(errors, ", ")
    end
  end
end
