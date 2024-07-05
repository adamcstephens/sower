import Config

if System.get_env("PHX_SERVER") do
  config :sower, SowerWeb.Endpoint, server: true
end

defmodule Sower.Config do
  require Logger

  @schema %{
    "type" => "object",
    "required" => ["auth", "database"],
    "properties" => %{
      "auth" => %{
        "type" => "object",
        "required" => ["oidc_base_url", "oidc_client_id"],
        "properties" => %{
          "oidc_base_url" => %{
            "type" => "string"
          },
          "oidc_client_id" => %{
            "type" => "string"
          },
          "oidc_client_secret_file" => %{
            "type" => "string"
          },
          "oidc_redirect_uri" => %{
            "type" => "string"
          }
        }
      },
      "database" => %{
        "type" => "object",
        "properties" => %{
          "host" => %{
            "type" => "string"
          },
          "database" => %{
            "type" => "string"
          },
          "port" => %{
            "type" => "integer",
            "minimum" => 80,
            "maximum" => 65535
          },
          "socket" => %{
            "type" => "string"
          },
          "user" => %{
            "type" => "string"
          },
          "password_file" => %{
            "type" => "string"
          }
        }
      },
      "public_url" => %{
        "type" => "string",
        "format" => "uri"
      },
      "listen_address" => %{
        "type" => "string",
        "format" => "ipv4"
      },
      "listen_port" => %{
        "default" => 4000,
        "type" => "integer",
        "minimum" => 80,
        "maximum" => 65535
      },
      "secret_key_base_file" => %{
        "type" => "string"
      }
    }
  }

  def load() do
    {:ok, _} = Application.ensure_all_started(:jason)
    {:ok, _} = Application.ensure_all_started(:logger)
    Logger.debug("Loading configuration")

    config_file = System.get_env("SOWER_SERVER_CONFIG_FILE", "/etc/sower/server.json")

    json_config =
      with {:ok, contents} <- File.read(config_file),
           {:ok, json} <- Jason.decode(contents),
           :ok <- ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(@schema), json) do
        json
      else
        {:error, _err} ->
          Logger.error(~s"Failed to read configuration file #{config_file}")
          Kernel.exit(1)
      end

    # set log level to atom and remove from config
    if Map.has_key?(json_config, "log_level") do
      level = Map.get(json_config, "log_level") |> String.to_existing_atom()
      Logger.info(~s"Overriding log level from config to #{level}")

      config :logger, :console, level: level
    end

    Logger.debug("Loaded configuration")
    Logger.debug(json_config)
    json_config = json_config |> Map.delete("log_level")

    # load some defaults
    public_url = json_config |> Map.get("public_url", "http://127.0.0.1:4000")
    put_config(:auth, oidc_redirect_uri: ~s"#{public_url}/auth")
    listen_address = json_config |> Map.get("listen_address", "127.0.0.1")
    listen_port = json_config |> Map.get("listen_port", 4000)

    secret_key_base =
      with %{"secret_key_base_file" => secret_key_base_file} <- json_config,
           {:ok, secret_key_base} <- read_credential(secret_key_base_file) do
        secret_key_base
      else
        {:error, err} ->
          Logger.warning("Failed to load secret_key_base from secret file, #{err}.")
          Kernel.exit(1)

        %{} ->
          Logger.warning("No secret_key_base_file in configuration. Exiting!")
          Kernel.exit(1)
      end

    json_config =
      with %{"database" => database} <- json_config,
           %{"password_file" => password_file} <- database,
           {:ok, password} <- read_credential(password_file) do
        json_config |> Map.put("database", database |> Map.put("password", password))
      else
        # assume missing password_file is intentional
        %{} ->
          Logger.debug("No database password_file to read.")
          json_config

        {:error, err} ->
          Logger.warning("Failed to load database password from file, #{err}.")
          json_config
      end

    json_config =
      with %{"auth" => auth} <- json_config,
           %{"oidc_client_secret_file" => oidc_client_secret_file} <- auth,
           {:ok, oidc_client_secret} <- read_credential(oidc_client_secret_file) do
        json_config |> Map.put("auth", auth |> Map.put("oidc_client_secret", oidc_client_secret))
      else
        {:error, err} ->
          Logger.warning("Failed to load oidc_client_secret from secret file, #{err}.")
          Kernel.exit(1)

        %{} ->
          Logger.warning("No auth.oidc_client_secret_file in configuration. Exiting!")
          Kernel.exit(1)
      end

    Logger.debug("Modified configuration")
    Logger.debug(json_config)

    json_config |> Enum.map(&load_config(&1))

    # load some non-app namespaced configs
    %URI{scheme: scheme, host: host, port: port} = URI.parse(public_url)

    put_config(SowerWeb.Endpoint,
      url: [host: host, port: port, scheme: scheme],
      http: [ip: ip_to_inet(listen_address), port: listen_port],
      secret_key_base: secret_key_base,
      persistent: true
    )

    Logger.info("Finished loading configuration")
  end

  defp load_config({config_atom, values}) when is_map(values) do
    config_atom = String.to_atom(config_atom)
    values = Keyword.new(values, fn {k, v} -> {String.to_atom(k), v} end)
    put_config(config_atom, values)
  end

  defp load_config({config_atom, value}) when is_binary(value) or is_number(value) do
    config_atom = String.to_atom(config_atom)
    put_config(config_atom, value)
  end

  defp read_credential(path) when is_binary(path) do
    case path |> File.read() do
      {:ok, content} ->
        {:ok, content |> String.trim()}

      other ->
        other
    end
  end

  defp put_config(config_atom, new_values) when is_atom(config_atom) and is_list(new_values) do
    config =
      case Application.fetch_env(:sower, config_atom) do
        {:ok, previous_values} -> Keyword.merge(previous_values, new_values)
        :error -> new_values
      end

    config(:sower, config_atom, config)
  end

  defp put_config(config_atom, new_value) when is_atom(config_atom) do
    config(:sower, config_atom, new_value)
  end

  defp ip_to_inet(ip) do
    case ip
         |> to_charlist()
         |> :inet.parse_address() do
      {:ok, ip} ->
        ip

      {:error, _err} ->
        Logger.error(~s"Failed to parse ip #{ip}")
        Kernel.exit(1)
    end
  end
end

Sower.Config.load()
