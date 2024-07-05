import Config

if System.get_env("PHX_SERVER") do
  config :sower, SowerWeb.Endpoint, server: true
end

defmodule Sower.Config do
  require Logger

  @credentials [
    "SOWER_AUTH_OIDC_CLIENT_SECRET_FILE"
  ]

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
          "pass_file" => %{
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

    Logger.debug("Loaded configuration")
    Logger.debug(json_config)

    # load some defaults
    public_url = json_config |> Map.get("public_url", "http://127.0.0.1:4000")
    put_config(:auth, oidc_redirect_uri: ~s"#{public_url}/auth")
    listen_address = json_config |> Map.get("listen_address", "127.0.0.1")
    listen_port = json_config |> Map.get("listen_port", 4000)

    # set log level to atom and remove from config
    if Map.has_key?(json_config, "log_level") do
      level = Map.get(json_config, "log_level") |> String.to_existing_atom()
      Logger.info(~s"Overriding log level from config to #{level}")

      config :logger, :console, level: level
    end

    json_config = json_config |> Map.delete("log_level")

    json_config
    |> Enum.map(&load_config(&1))

    @credentials |> Enum.map(&load_credential(&1))

    # load some non-app namespaced configs
    %URI{scheme: scheme, host: host, port: port} = URI.parse(public_url)

    put_config(SowerWeb.Endpoint,
      url: [host: host, port: port, scheme: scheme],
      http: [ip: ip_to_inet(listen_address), port: listen_port],
      secret_key_base: credential!("SOWER_SECRET_KEY_BASE_FILE"),
      persistent: true
    )

    Logger.info("Finished loading configuration")
  end

  defp load_config({config_atom, values}) when is_map(values) do
    config_atom = String.to_atom(config_atom)
    values = Keyword.new(values, fn {k, v} -> {String.to_atom(k), v} end)
    put_config(config_atom, values)
  end

  defp load_config({config_atom, value}) when is_binary(value) do
    config_atom = String.to_atom(config_atom)
    put_config(config_atom, value)
  end

  defp credential(name) do
    credential_dir = System.get_env("CREDENTIALS_DIRECTORY")
    credential = System.get_env(name)

    case read_credential(name, credential_dir, credential) do
      {:ok, value} -> {:ok, value |> String.trim()}
      {:error, err} -> {:error, ~s"unable to load credential #{name}, #{err}"}
    end
  end

  defp load_credential(cred) when is_binary(cred) do
    Logger.debug(~s"Loading credential #{cred}")

    captures =
      ~r/SOWER_(?<section>[[:alnum:]]+)_(?<key>.+)_FILE/
      |> Regex.named_captures(cred)

    if captures == nil do
      Logger.error(~s"Credential #{cred} cannot be parsed")
      Kernel.exit(1)
    end

    section = captures["section"] |> String.downcase() |> String.to_atom()

    key = captures["key"] |> String.downcase() |> String.to_atom()

    case credential(cred) do
      {:ok, path} ->
        put_config(section, [{key, path}])
        :ok

      {:error, _err} ->
        :error
    end
  end

  def credential!(name) do
    case credential(name) do
      {:ok, value} -> value
      {:error, err} -> raise err
    end
  end

  defp read_credential(name, nil, nil) do
    Logger.warning(~s"Could not load credential from env: #{name}")
    {:error, "not found"}
  end

  defp read_credential(_, nil, cred), do: read_credential(cred)

  defp read_credential(name, dir, nil), do: read_credential(~s"#{dir}/#{name}")
  defp read_credential(_, dir, cred), do: read_credential(~s"#{dir}/#{cred}")
  defp read_credential(path) when is_binary(path), do: path |> File.read()

  defp read_credential(nil) do
    Logger.error("Could not find credential")
    Kernel.exit(1)
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
