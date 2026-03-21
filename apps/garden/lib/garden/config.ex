defmodule Garden.Config do
  @moduledoc """
  Garden configuration management.
  """

  require Logger

  @app :garden

  def get do
    Application.get_env(@app, :config)
  end

  def load(config_map \\ %{}, opts \\ []) do
    cfg =
      SowerClient.Config.load(
        overrides: config_map,
        skip_config_file: Keyword.get(opts, :skip_config_file, false)
      )

    cfg =
      if Keyword.get(opts, :validate, true) do
        validate_required!(cfg)
      else
        cfg
      end

    cfg = process_side_effects(cfg)

    Application.put_env(@app, :config, cfg)
    cfg
  end

  def reload do
    Application.put_env(:garden, :config, load(%{}))
    Application.stop(:garden)
    Application.start(:garden)
  end

  defp validate_required!(%SowerClient.Config{} = config) do
    errors = []

    errors =
      if is_nil(config.endpoint) do
        ["endpoint is required" | errors]
      else
        errors
      end

    errors =
      if is_nil(config.access_token) do
        ["access_token is required" | errors]
      else
        errors
      end

    case errors do
      [] ->
        config

      _ ->
        Logger.error(msg: "Configuration validation failed", errors: errors)
        Kernel.exit(1)
    end
  end

  defp process_side_effects(%SowerClient.Config{} = config) do
    # Configure websocket client (only if endpoint is set)
    if config.endpoint do
      uri = URI.parse(config.endpoint)

      uri =
        Map.put(uri, :scheme, String.replace(uri.scheme, "http", "ws"))
        |> Map.put(
          :path,
          case uri.path do
            nil ->
              "/garden/websocket"

            p when is_binary(p) ->
              if String.ends_with?(p, "garden/websocket") do
                p
              else
                p <> "/garden/websocket"
              end
          end
        )

      Application.put_env(Garden.Socket, :uri, uri)
      Application.put_env(Garden.Socket, :reconnect_after_msec, [200, 500, 1_000, 2_000])
    end

    # Expand state_directory path
    %{config | state_directory: Path.expand(config.state_directory)}
  end
end
