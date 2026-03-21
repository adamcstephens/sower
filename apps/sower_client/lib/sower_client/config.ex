defmodule SowerClient.Config do
  @moduledoc """
  Shared configuration for Sower tools (garden, CLI).

  Supports `_file` suffix for reading secrets from files.

  Default config location: `~/.config/sower/client.json` or `/etc/sower/client.json`
  """

  use TypedStruct
  alias OpenApiSpex.Schema
  require Logger
  require OpenApiSpex

  @config_file_env "SOWER_CONFIG_FILE"
  @path_setting_keys ["state_directory"]
  @env_var_pattern ~r/\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})/

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
        description: "Garden name (garden-only)"
      },
      state_directory: %Schema{
        type: :string,
        description: "Directory where state files are written (garden-only)"
      },
      default_deployment_profile: %Schema{
        type: :string,
        description: "Name of default deployment profile",
        nullable: true
      },
      deployment_profiles: %Schema{
        type: :object,
        additionalProperties: SowerClient.Orchestration.DeploymentProfile,
        nullable: true,
        description: "Deployment policies (garden-only)"
      },
      subscriptions: %Schema{
        type: :array,
        items: SowerClient.Orchestration.Subscription,
        default: [],
        description: "Subscriptions (garden-only)"
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

    # ensure elixir configs aren't atom-keyed
    config_overrides =
      opts |> Keyword.get(:overrides, %{}) |> Map.new(fn {k, v} -> {to_string(k), v} end)

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
            Map.put(merged, "config_path", config_path)
          else
            merged
          end
        end)
      end
    end)
    |> preprocess_subscription_rules()
    |> Map.merge(config_overrides)
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
      "default" => "/var/lib/sower-garden"
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

    path
    |> expand_path!("config_path")
    |> Path.absname()
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
    hostname =
      case :inet.gethostname() do
        {:ok, value} -> to_string(value)
        _ -> "unknown-host"
      end

    case System.get_env("USER") do
      user when is_binary(user) ->
        user = String.trim(user)

        if user == "" or user == "sower-garden" do
          hostname
        else
          "#{user}@#{hostname}"
        end

      _ ->
        hostname
    end
  end

  def default_state_dir do
    SowerClient.Config.xdg_state_path("sower-garden")
  end

  def xdg_config_path(app_name, filename) do
    system_config = Path.join(["/etc", app_name, filename])

    case System.get_env("USER") do
      user when user != "root" ->
        f = xdg_path_file(:config, app_name, filename)

        if File.exists?(f), do: f, else: system_config

      _ ->
        system_config
    end
  end

  def xdg_state_path(app_name) do
    case System.get_env("USER") do
      user when user != "root" ->
        case System.get_env("STATE_DIRECTORY") do
          nil ->
            xdg_path_file(:state, app_name, nil)

          state ->
            expand_path!(state, "STATE_DIRECTORY")
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
        |> expand_path!("XDG_CONFIG_HOME")
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
        |> expand_path!("XDG_STATE_HOME")
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
    |> expand_known_path_values()
    |> Enum.map(fn {key, value} ->
      key =
        if is_atom(key) do
          Atom.to_string(key)
        else
          key
        end

      if not is_nil(value) and String.ends_with?(key, "_file") do
        real_key = String.trim_trailing(key, "_file")

        if Map.has_key?(config_map, real_key) or
             Map.has_key?(config_map, String.to_existing_atom(real_key)) do
          # Base key exists, skip file read and drop the _file key
          nil
        else
          value =
            value
            |> expand_path!(key)
            |> Path.absname()
            |> File.read!()
            |> String.trim()

          {real_key, value}
        end
      else
        {key, value}
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp expand_known_path_values(config_map) do
    Enum.reduce(config_map, config_map, fn {key, value}, acc ->
      setting_key = to_string(key)

      if setting_key in @path_setting_keys and is_binary(value) do
        Map.put(acc, key, expand_path!(value, setting_key))
      else
        acc
      end
    end)
  end

  defp expand_path!(value, _setting_name) when not is_binary(value), do: value

  defp expand_path!(value, setting_name) do
    value
    |> expand_home_token()
    |> expand_env_tokens(setting_name)
  end

  defp expand_home_token("~"), do: user_home!()

  defp expand_home_token("~/" <> rest) do
    Path.join(user_home!(), rest)
  end

  defp expand_home_token(value), do: value

  defp expand_env_tokens(value, setting_name) do
    Regex.replace(@env_var_pattern, value, fn _full, plain, wrapped ->
      var_name = plain || wrapped

      case System.get_env(var_name) do
        nil ->
          raise ArgumentError,
                "Invalid path for #{setting_name}: missing environment variable #{var_name}"

        env_value ->
          env_value
      end
    end)
  end

  defp user_home!() do
    case System.user_home() do
      nil -> raise ArgumentError, "Cannot expand '~': user home directory is unavailable"
      home -> home
    end
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
