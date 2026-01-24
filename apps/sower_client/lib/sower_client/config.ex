defmodule SowerClient.Config do
  @moduledoc """
  Shared configuration for Sower tools (agent, CLI).

  Supports `_file` suffix for reading secrets from files.

  Default config location: `~/.config/sower/client.json` or `/etc/sower/client.json`
  """

  use TypedStruct
  alias OpenApiSpex.Schema
  require Logger
  require OpenApiSpex

  @config_file_env "SOWER_CONFIG_FILE"

  OpenApiSpex.schema(%{
    title: "Config",
    type: :object,
    properties: %{
      access_token: %Schema{
        type: :string,
        description: "Sower access token",
        readOnly: true
      },
      caches: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Default cache URLs for pushing builds",
        example: ["attic://server:cache"]
      },
      config_path: %Schema{
        type: :string,
        description: "config file path",
        readOnly: true
      },
      endpoint: %Schema{
        type: :string,
        format: :uri,
        description: "Sower server endpoint",
        example: "https://my.sower.dev"
      },
      name: %Schema{
        type: :string,
        description: "Agent name (agent-only)"
      },
      state_directory: %Schema{
        type: :string,
        description: "Directory where state files are written (agent-only)"
      },
      subscriptions: %Schema{
        type: :array,
        items: SowerClient.Orchestration.Subscription,
        default: [],
        description: "Agent subscriptions (agent-only)"
      }
    },
    required: []
  })

  @doc """
  Load configuration from file and overrides.
  """
  def load(opts \\ []) do
    Application.ensure_all_started(:logger)

    spec = build_spec()
    skip_config_file = Keyword.get(opts, :skip_config_file, false)
    config_path = resolve_config_path(opts)

    defaults()
    |> Map.merge(Keyword.get(opts, :defaults, %{}))
    |> then(fn cfg ->
      if skip_config_file do
        cfg
      else
        cfg
        |> Map.merge(read_config_file(config_path))
        |> then(fn merged ->
          if File.exists?(config_path) do
            Map.put(merged, :config_path, config_path)
          else
            merged
          end
        end)
      end
    end)
    |> preprocess_subscription_rules()
    |> Map.merge(Keyword.get(opts, :overrides, %{}))
    |> override_with_env()
    |> parse_file_values()
    |> OpenApiSpex.cast_value(spec.components.schemas["Config"], spec)
    |> case do
      {:ok, cfg} ->
        cfg

      {:error, errors} ->
        Logger.error(msg: "Failed to read configuration", errors: errors)
        Kernel.exit(1)
    end
    |> process_side_effects()
  end

  def defaults() do
    %{
      "name" => default_client_name(),
      "state_directory" => default_state_dir(),
      "default" => "/var/lib/sower-agent"
    }
  end

  def build_spec do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{title: "Config", version: "1.0.0"},
      paths: %{},
      components: nil
    }
    |> OpenApiSpex.resolve_schema_modules()
    |> OpenApiSpex.add_schemas([__MODULE__])
  end

  def read_config_file(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> Jason.decode!()
    else
      Logger.debug(msg: "Config file is missing, using defaults only", file: path)
      %{}
    end
  end

  @doc """
  Resolve config file path from options and environment.

  Config path resolution order:
  1. Explicit `:config_path` option
  2. From env `$SOWER_CONFIG_FILE`
  3. XDG path: `~/.config/sower/client.json` or `/etc/sower/client.json`
  """
  def resolve_config_path(opts) do
    explicit_path = Keyword.get(opts, :config_path)

    path =
      if explicit_path do
        explicit_path
      else
        default_config_path()
      end

    Path.absname(path)
  end

  @doc """
  Default config file path.

  Uses `$SOWER_CONFIG_FILE` if set.

  Otherwise, returns `~/.config/sower/client.json` for non-root users,
  `/etc/sower/client.json` for root.
  """
  def default_config_path() do
    System.get_env(
      @config_file_env,
      xdg_config_path("sower", "client.json")
    )
  end

  def default_client_name() do
    :inet.gethostname() |> then(fn {:ok, hostname} -> to_string(hostname) end)
  end

  def default_state_dir do
    SowerClient.Config.xdg_state_path("sower_agent")
  end

  def xdg_config_path(app_name, filename) do
    case System.get_env("USER") do
      user when user != "root" ->
        xdg_path_file(:config, app_name, filename)

      _ ->
        Path.join(["/etc", app_name, filename])
    end
  end

  def xdg_state_path(app_name) do
    case System.get_env("USER") do
      user when user != "root" ->
        case System.get_env("STATE_DIRECTORY") do
          nil ->
            xdg_path_file(:state, app_name, nil)

          state ->
            state
        end

      _ ->
        Path.join("/var/lib", app_name)
    end
  end

  defp xdg_path_file(:config, app_name, filename) do
    case System.get_env("XDG_CONFIG_HOME", home_default(".config")) do
      nil ->
        nil

      path ->
        path
        |> Path.join(app_name)
        |> Path.join(filename)
    end
  end

  defp xdg_path_file(:state, app_name, _filename) do
    case System.get_env("XDG_STATE_HOME", home_default(".local/state")) do
      nil ->
        nil

      path ->
        path
        |> Path.join(app_name)
    end
  end

  defp home_default(subdir) do
    case System.get_env("HOME") do
      nil -> nil
      home -> Path.join(home, subdir)
    end
  end

  @doc """
  Parse `_file` suffixes in config keys.

  Converts keys ending in `_file` to their base name and reads the file content.
  For example, `access_token_file: "/path/to/token"` becomes `access_token: "contents"`.
  """
  def parse_file_values(config_map) do
    config_map
    |> Enum.map(fn {key, value} ->
      key =
        if is_atom(key) do
          Atom.to_string(key)
        else
          key
        end

      if not is_nil(value) and String.ends_with?(key, "_file") do
        real_key = String.trim_trailing(key, "_file")
        value = value |> Path.absname() |> File.read!() |> String.trim()
        {real_key, value}
      else
        {key, value}
      end
    end)
    |> Map.new()
  end

  # parse subscriptions and rules
  defp preprocess_subscription_rules(%{"subscriptions" => subscriptions} = config)
       when is_list(subscriptions) do
    normalized_subscriptions =
      subscriptions
      |> Enum.map(&parse_subscription_rules/1)
      |> Enum.map(&fill_default_subscription_name/1)

    Map.put(config, "subscriptions", normalized_subscriptions)
  end

  defp preprocess_subscription_rules(config), do: config

  defp parse_subscription_rules(%{"rules" => rules} = sub) when is_list(rules) do
    normalized_rules =
      Enum.map(rules, fn rule ->
        case rule do
          rule when is_binary(rule) ->
            SowerClient.SubscriptionRuleFormat.parse!(rule)

          rule when is_map(rule) ->
            rule
        end
      end)

    Map.put(sub, "rules", normalized_rules)
  end

  defp parse_subscription_rules(sub), do: sub

  defp fill_default_subscription_name(%{"seed_type" => "nixos"} = sub) do
    Map.put(sub, "seed_name", Map.get(sub, "seed_name", default_client_name()))
  end

  defp fill_default_subscription_name(sub), do: sub

  defp process_side_effects(%SowerClient.Config{} = config) do
    # Configure websocket client (only if endpoint is set)
    if config.endpoint do
      uri = URI.parse(config.endpoint)

      uri =
        Map.put(
          uri,
          :path,
          case uri.path do
            nil ->
              "/api/v1"

            p when is_binary(p) ->
              if String.ends_with?(p, "api/v1") do
                p
              else
                p <> "/api/v1"
              end
          end
        )

      Application.put_env(SowerClient.ApiClient, :uri, uri)
    end

    Application.put_env(SowerClient.ApiClient, :token, config.access_token)
    Application.put_env(SowerClient.ApiClient, :reconnect_after_msec, [200, 500, 1_000, 2_000])

    # Expand state_directory path
    %{config | state_directory: Path.expand(config.state_directory)}
  end

  defp override_with_env(%{} = config) do
    sower_envs =
      System.get_env() |> Enum.filter(fn {key, _} -> String.starts_with?(key, "SOWER_") end)

    Enum.reduce(sower_envs, config, &override_env/2)
  end

  defp override_env({"SOWER_ACCESS_TOKEN_FILE", token}, acc) do
    Map.put(acc, "access_token_file", token)
  end

  defp override_env({"SOWER_ACCESS_TOKEN", token}, acc) do
    Map.put(acc, "access_token", token)
  end

  defp override_env({"SOWER_ENDPOINT", token}, acc) do
    Map.put(acc, "endpoint", token)
  end

  defp override_env(_, acc), do: acc
end
