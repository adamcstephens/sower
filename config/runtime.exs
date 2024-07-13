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
      "clients" => %{
        "type" => "object",
        "properties" => %{
          "x86_64-linux" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string"
              }
            }
          },
          "aarch64-linux" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string"
              }
            }
          },
          "x86_64-darwin" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string"
              }
            }
          },
          "aarch64-darwin" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{
                "type" => "string"
              }
            }
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
      "nix_caches" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "public_key" => %{
              "type" => "string"
            },
            "url" => %{
              "type" => "string",
              "format" => "uri"
            }
          }
        },
        "required" => ["public_key"]
      },
      "public_url" => %{
        "type" => "string",
        "format" => "uri"
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

    defaults = %{
      "listen_address" => "127.0.0.1",
      "listen_port" => 4000,
      "nix_caches" => []
    }

    json_config =
      with {:ok, contents} <- File.read(config_file),
           {:ok, json} <- Jason.decode(contents),
           :ok <- ExJsonSchema.Validator.validate(ExJsonSchema.Schema.resolve(@schema), json) do
        defaults |> Map.merge(json) |> atomize()
      else
        {:error, err} ->
          Logger.error(~s"Failed to read configuration file #{config_file}")
          Logger.error(err)
          Kernel.exit(1)
      end

    # set log level to atom and remove from config
    if Keyword.has_key?(json_config, :log_level) do
      level = Keyword.get(json_config, :log_level) |> String.to_existing_atom()
      Logger.info(~s"Overriding log level from config to #{level}")

      config :logger, :console, level: level
    end

    Logger.debug("Loaded configuration")
    Logger.debug(json_config)
    json_config = json_config |> Keyword.delete(:log_level)

    # compute urls
    public_url = json_config |> Keyword.fetch!(:public_url)

    json_config =
      json_config
      |> Keyword.put(
        :auth,
        json_config
        |> Keyword.fetch!(:auth)
        |> Keyword.put(:oidc_redirect_uri, ~s"#{public_url}/auth")
      )

    secret_key_base =
      with {:ok, secret_key_base_file} <- json_config |> Keyword.fetch(:secret_key_base_file),
           {:ok, secret_key_base} <- read_credential(secret_key_base_file) do
        secret_key_base
      else
        :error ->
          Logger.warning("Configuration is missing `secret_key_base_file`.")
          Kernel.exit(1)

        {:error, err} ->
          Logger.warning("Failed to load secret_key_base from secret file, #{err}.")
          Kernel.exit(1)
      end

    # database password file
    json_config =
      with {:ok, database} <- json_config |> Keyword.fetch(:database),
           {:ok, password_file} <- database |> Keyword.fetch(:password_file),
           {:ok, password} <- read_credential(password_file) do
        json_config |> Keyword.put(:database, database |> Keyword.put(:password, password))
      else
        # assume missing password_file is intentional
        :error ->
          Logger.debug("Configuration does not have `database.password_file` to read. Skipping.")
          json_config

        {:error, err} ->
          Logger.warning("Failed to load database password from file, #{err}.")
          json_config
      end

    # oidc client secret file
    json_config =
      with {:ok, auth} <- json_config |> Keyword.fetch(:auth),
           {:ok, oidc_client_secret_file} <- auth |> Keyword.fetch(:oidc_client_secret_file),
           {:ok, oidc_client_secret} <- read_credential(oidc_client_secret_file) do
        json_config
        |> Keyword.put(:auth, auth |> Keyword.put(:oidc_client_secret, oidc_client_secret))
      else
        {:error, err} ->
          Logger.warning("Failed to load oidc_client_secret from secret file, #{err}.")
          Kernel.exit(1)

        :error ->
          Logger.warning("Configuration is missing `auth.oidc_client_secret_file`.")
          Kernel.exit(1)
      end

    Logger.debug("Final configuration:")
    Logger.debug(json_config)

    json_config |> Enum.map(fn {k, v} -> put_config(k, v) end)

    # load some non-app namespaced configs
    %URI{scheme: scheme, host: host, port: port} = URI.parse(public_url)

    put_config(SowerWeb.Endpoint,
      url: [host: host, port: port, scheme: scheme],
      http: [
        ip: ip_to_inet(json_config |> Keyword.fetch!(:listen_address)),
        port: json_config |> Keyword.fetch!(:listen_port)
      ],
      secret_key_base: secret_key_base,
      persistent: true
    )

    Logger.info("Finished loading configuration.")
  end

  defp atomize([head | rest]) do
    [atomize(head)] ++ atomize(rest)
  end

  defp atomize(map = %{}) do
    map
    |> Enum.map(fn {k, v} -> {String.to_atom(k), atomize(v)} end)
  end

  defp atomize(nil), do: nil
  defp atomize(other), do: other

  defp read_credential(path) when is_binary(path) do
    case path |> File.read() do
      {:ok, content} ->
        {:ok, content |> String.trim()}

      other ->
        other
    end
  end

  defp read_credential(nil), do: {:error, :is_nil}

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
