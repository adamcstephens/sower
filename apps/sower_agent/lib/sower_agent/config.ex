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
      config_path: %Schema{
        type: :string,
        description: "config file path",
        readOnly: true
      },
      endpoint: %Schema{
        type: :string,
        format: :uri,
        description: "Sower endpoint",
        example: "https://my.sower.dev"
      },
      name: %Schema{
        type: :string,
        description: "Agent name",
        default: "system hostname"
      },
      state_directory: %Schema{
        type: :string,
        description: "directory where state files are written",
        default: "/var/lib/sower_agent"
      },
      subscriptions: %Schema{
        type: :array,
        items: SowerClient.Schemas.Orchestration.Subscription,
        default: []
      }
    },
    required: [:access_token, :endpoint]
  })

  def get() do
    Application.get_env(@app, :config)
  end

  def load(config_map \\ %{}) do
    Application.ensure_all_started(:logger)

    spec =
      %OpenApiSpex.OpenApi{
        info: %OpenApiSpex.Info{title: "Config", version: "1.0.0"},
        paths: %{},
        components: nil
      }
      |> OpenApiSpex.resolve_schema_modules()
      |> OpenApiSpex.add_schemas([SowerAgent.Config])

    cfg =
      defaults()
      |> Map.merge(config_map)
      |> add_config_file()
      |> parse_files_to_values()
      |> OpenApiSpex.cast_value(spec.components.schemas["Config"], spec)
      |> case do
        {:ok, cfg} ->
          cfg

        {:error, errors} ->
          Logger.error(msg: "Failed to read configuration", errors: errors)
          Kernel.exit(1)
      end

    # process side effects
    cfg =
      cfg
      |> Map.to_list()
      |> Enum.map(&external_config/1)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    # cast back into a struct
    cfg = struct(__MODULE__, cfg)

    Application.put_env(@app, :config, cfg)
  end

  @doc """
  external_config is processed for each child in the config.
  It allows for mapping from a config file format to elixir native config manually.
  """
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

  def external_config({:state_directory, dir}) do
    {:state_directory, Path.expand(dir)}
  end

  def external_config({:__struct__, _}), do: nil

  def external_config(cfg), do: cfg

  def add_config_file(cfg) do
    cfg
    |> Map.merge(read_config_file(cfg["config_path"]))
  end

  def defaults() do
    %{
      "name" => default_agent_name(),
      "config_path" => System.get_env("SOWER_AGENT_CONFIG", default_config_file()),
      "state_directory" => default_state_dir()
    }
  end

  def default_agent_name() do
    :inet.gethostname() |> then(fn {:ok, hostname} -> to_string(hostname) end)
  end

  def default_state_dir() do
    case System.get_env("USER") do
      user when user != "root" ->
        System.get_env("XDG_STATE_HOME", Path.join(System.fetch_env!("HOME"), ".local/state"))
        |> Path.join("sower_agent")

      _ ->
        "/var/lib/sower_agent"
    end
  end

  def read_config_file(file) when not is_nil(file) do
    file = Path.absname(file)

    if File.exists?(file) do
      file
      |> File.read!()
      |> Jason.decode!()
      |> normalize_subscription_rules()
    else
      Logger.warning(msg: "Config file is missing!", file: file)
      %{}
    end
  end

  defp normalize_subscription_rules(%{"subscriptions" => subscriptions} = config)
       when is_list(subscriptions) do
    normalized_subscriptions =
      Enum.map(subscriptions, fn subscription ->
        case subscription do
          %{"rules" => rules} when is_list(rules) ->
            normalized_rules =
              Enum.map(rules, fn rule ->
                case rule do
                  rule when is_binary(rule) ->
                    SowerClient.SubscriptionRuleFormat.parse!(rule)

                  rule when is_map(rule) ->
                    rule
                end
              end)

            Map.put(subscription, "rules", normalized_rules)

          subscription ->
            subscription
        end
      end)

    Map.put(config, "subscriptions", normalized_subscriptions)
  end

  defp normalize_subscription_rules(config), do: config

  def default_config_file() do
    case System.get_env("USER") do
      user when user != "root" ->
        System.get_env("XDG_CONFIG_HOME", Path.join(System.fetch_env!("HOME"), ".config"))
        |> Path.join("sower/agent.json")

      _ ->
        "/etc/sower/agent.json"
    end
  end

  def reload() do
    Application.put_env(:sower_agent, :config, load(%{}))
    Application.stop(:sower_agent)
    Application.start(:sower_agent)
  end

  defp parse_files_to_values(config_map) do
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
        value = value |> Path.absname() |> File.read!() |> String.trim()
        {real_key, value}
      else
        {key, value}
      end
    end)
    |> Map.new()
  end
end
