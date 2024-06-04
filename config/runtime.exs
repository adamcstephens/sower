import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/sower start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :sower, SowerWeb.Endpoint, server: true
end

config :sower, oidc_base_url: System.get_env("SOWER_AUTH_OIDC_BASE_URL")

if config_env() == :prod do
  host = System.get_env("SOWER_HOSTNAME") || raise "missing $SOWER_HOSTNAME"
  scheme = System.get_env("SOWER_PUBLIC_SCHEME", "https")
  public_port = String.to_integer(System.get_env("SOWER_PUBLIC_PORT", "443"))

  config :sower,
    bootstrap_token: Sower.Application.credential!("SOWER_BOOTSTRAP_TOKEN_FILE"),
    oidc_base_url:
      System.get_env("SOWER_AUTH_OIDC_BASE_URL") || raise("missing $SOWER_AUTH_OIDC_BASE_URL"),
    oidc_client_id: Sower.Application.credential!("SOWER_AUTH_OIDC_CLIENT_ID_FILE"),
    oidc_client_secret: Sower.Application.credential!("SOWER_AUTH_OIDC_CLIENT_SECRET_FILE"),
    oidc_redirect_uri:
      System.get_env("SOWER_AUTH_OIDC_REDIRECT_URI", ~s"#{scheme}://#{host}:#{public_port}/auth")

  if System.get_env() |> Map.has_key?("SOWER_DATABASE_SOCKET") do
    config :sower, Sower.Repo,
      socket: System.get_env("SOWER_DATABASE_SOCKET"),
      database: System.get_env("SOWER_DATABASE_NAME", "sower")
  else
    config :sower, Sower.Repo,
      username: System.get_env("SOWER_DATABASE_USER", "sower"),
      password: Sower.Application.credential!("SOWER_DATABASE_PASS_FILE"),
      hostname: System.get_env("SOWER_DATABASE_HOST", "localhost"),
      database: System.get_env("SOWER_DATABASE_NAME", "sower"),
      port: System.get_env("SOWER_DATABASE_PORT", "5432") |> String.to_integer()
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base = Sower.Application.credential!("SECRET_KEY_BASE_FILE")

  port = String.to_integer(System.get_env("SOWER_LISTEN_PORT", "4000"))

  {:ok, listen_ip} =
    System.get_env("SOWER_LISTEN_ADDRESS", "127.0.0.1")
    |> to_charlist()
    |> :inet.parse_address()

  config :sower, SowerWeb.Endpoint,
    url: [host: host, port: public_port, scheme: scheme],
    http: [ip: listen_ip, port: port],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :sower, SowerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your endpoint, ensuring
  # no data is ever sent via http, always redirecting to https:
  #
  #     config :sower, SowerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :sower, Sower.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
