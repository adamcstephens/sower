defmodule Garden.Config do
  @moduledoc """
  Loads garden configuration and maintains runtime WebSocket settings.

  Socket settings are refreshed for each connection attempt so environment proxy
  changes, bypass rules, and endpoint reloads cannot retain stale proxy credentials.
  """

  require Logger

  @app :garden

  def get do
    Application.get_env(@app, :config)
  end

  def socket_config do
    config = Application.get_env(@app, Garden.Socket, [])
    uri = Keyword.fetch!(config, :uri)
    mint_opts = Keyword.get(config, :mint_opts, [])

    case SowerClient.Proxy.mint_options(uri, mint_opts) do
      {:ok, mint_opts} ->
        config = Keyword.put(config, :mint_opts, mint_opts)
        Application.put_env(@app, Garden.Socket, config)
        {:ok, config}

      {:error, error} ->
        {:error, error}
    end
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
      if config.endpoint && is_nil(config.access_token) do
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

      socket_config =
        Application.get_env(@app, Garden.Socket, [])
        |> Keyword.put(:uri, uri)
        |> Keyword.put(:reconnect_after_msec, Garden.Socket.Lifecycle.default_backoff())

      Application.put_env(@app, Garden.Socket, socket_config)
    end

    # Expand state_directory path
    %{config | state_directory: Path.expand(config.state_directory)}
  end
end
