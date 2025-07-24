defmodule SowerAgent.Config do
  alias OpenApiSpex.Schema
  require Logger
  require OpenApiSpex

  # Could you define a behavior with different runtime/compiletime callbacks
  # with a simple Mod.func call in config which would be an entrypoint

  @app :sower_agent

  OpenApiSpex.schema(%{
    title: "Config",
    type: :object,
    properties: %{
      access_token: %Schema{
        type: :string,
        description: "Sower access token",
        readOnly: true
      },
      endpoint: %Schema{
        type: :string,
        format: :uri,
        description: "Sower endpoint",
        example: "https://my.sower.dev"
      },
      state_directory: %Schema{
        type: :string,
        description: "directory where state files are written",
        default: "/var/lib/sower_agent"
      },
      subscriptions: %Schema{
        type: :array,
        items: SowerClient.Schemas.Orchestration.Subscription.schema()
      }
    },
    required: ~w(access_token endpoint)a
  })

  def get() do
    Application.get_env(@app, :config)
  end

  def load(config_map) do
    cfg =
      case config_map
           |> read_files()
           |> OpenApiSpex.cast_value(schema()) do
        {:ok, cfg} ->
          cfg

        {:error, errors} ->
          Logger.error(msg: "Failed to read configuration", errors: errors)
          Kernel.exit(1)
      end

    # process side effects
    cfg
    |> Map.to_list()
    |> Enum.map(&external_config/1)
    |> Enum.reject(&is_nil/1)

    Application.put_env(@app, :config, cfg)
  end

  def external_config({:endpoint, endpoint}) do
    uri = URI.parse(endpoint)

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

    Application.put_env(SowerAgent.SocketClient, :uri, uri)
    Application.put_env(SowerAgent.SocketClient, :reconnect_after_msec, [200, 500, 1_000, 2_000])

    nil
  end

  def external_config(cfg), do: cfg

  def reload() do
    Application.put_env(:sower_agent, :config, load(%{}))
    Application.stop(:sower_agent)
    Application.start(:sower_agent)
  end

  defp read_files(config_map) do
    config_map
    |> Enum.map(fn {key, value} ->
      key =
        if is_atom(key) do
          Atom.to_string(key)
        else
          key
        end

      if String.ends_with?(key, "_file") do
        real_key = String.trim(key, "_file")
        {real_key, value |> File.read!() |> String.trim()}
      else
        {key, value}
      end
    end)
    |> Map.new()
  end
end
