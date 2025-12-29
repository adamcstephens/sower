defmodule SowerAgent.Config do
  @moduledoc """
  Agent configuration management.
  """

  require Logger

  @app :sower_agent

  def get do
    Application.get_env(@app, :config)
  end

  def load(config_map \\ %{}) do
    cfg =
      SowerClient.Config.load(config_map,
        defaults: defaults()
      )
      |> validate_required!()
      |> process_side_effects()

    Application.put_env(@app, :config, cfg)
    cfg
  end

  def defaults do
    %{
      "name" => default_agent_name(),
      "state_directory" => default_state_dir()
    }
  end

  def default_agent_name do
    :inet.gethostname() |> then(fn {:ok, hostname} -> to_string(hostname) end)
  end

  def default_state_dir do
    SowerClient.Config.xdg_state_path("sower_agent")
  end

  def reload do
    Application.put_env(:sower_agent, :config, load(%{}))
    Application.stop(:sower_agent)
    Application.start(:sower_agent)
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
    # Configure websocket client
    uri = URI.parse(config.endpoint)

    uri =
      Map.put(uri, :scheme, String.replace(uri.scheme, "http", "ws"))
      |> Map.put(
        :path,
        case uri.path do
          nil ->
            "/agent/websocket"

          p when is_binary(p) ->
            if String.ends_with?(p, "agent/websocket") do
              p
            else
              p <> "/agent/websocket"
            end
        end
      )

    Application.put_env(SowerAgent.Client, :uri, uri)
    Application.put_env(SowerAgent.Client, :reconnect_after_msec, [200, 500, 1_000, 2_000])

    # Expand state_directory path
    %{config | state_directory: Path.expand(config.state_directory)}
  end
end
