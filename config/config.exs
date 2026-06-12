# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :sower, ecto_repos: [Sower.Repo]

config :sower, Sower.Repo,
  migration_primary_key: [type: :identity],
  # store with usec mostly to avoid having to truncate utc_now()
  migration_timestamps: [type: :utc_datetime_usec]

# Configures the endpoint
config :sower, SowerWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: SowerWeb.ErrorHTML, json: SowerWeb.Api.ErrorJSON],
    layout: false
  ],
  pubsub_server: Sower.PubSub,
  live_view: [signing_salt: "nrwHFIM7"]

config :boruta, Boruta.Oauth,
  repo: Sower.Repo,
  issuer: "sower",
  contexts: [
    access_tokens: Boruta.Ecto.AccessTokens,
    clients: Boruta.Ecto.Clients,
    codes: Boruta.Ecto.Codes,
    scopes: Boruta.Ecto.Scopes
  ],
  max_ttl: [
    access_token: 2_592_000,
    authorization_code: 60,
    id_token: 86_400,
    refresh_token: 2_592_000
  ],
  token_generator: Boruta.TokenGenerator

config :flop, repo: Sower.Repo

config :sower, Sower.Orchestration,
  stale_after_seconds: 2 * 60 * 60,
  stale_batch_size: 100

config :sower, Sower.Orchestration.StaleDeploymentFinalizer, interval_ms: :timer.minutes(5)

# Configure esbuild. ESBUILD_PATH points at an externally provided binary
# (set by the nix builds); when unset, mix downloads the default version.
config :esbuild,
  version_check: false,
  path: System.get_env("ESBUILD_PATH"),
  sower: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../apps/sower/assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind. TAILWIND_PATH points at an externally provided binary
# (set by the nix builds); when unset, mix downloads the default version.
config :tailwind,
  version_check: false,
  path: System.get_env("TAILWIND_PATH"),
  sower: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../apps/sower/assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  level: :debug,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :mfa]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :sower, :generators,
  migration: true,
  timestamp_type: :utc_datetime_usec

config :elixir, time_zone_database: Zoneinfo.TimeZoneDatabase
config :zoneinfo, tzpath: System.get_env("TZDIR", "/etc/zoneinfo")

config :ex_aws, http_client: ExAws.Request.Req
config :ex_aws_s3, :content_hash_algorithm, :sha256

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
