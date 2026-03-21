import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :sower, Sower.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "sower_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :sower, SowerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "+qA3jXKscezV25y28C5SmMaQum/CvKrh0+1obODeDAlsBR8V94RaTB0rp8lDVhB9",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

config :sower, :database,
  encryption_key: "UIFQeYN5EBgkXgK502I8mosh3vbEj3AE1rRwWJDysBk=" |> Base.decode64!()

config :garden, Garden.Socket,
  uri: "ws://example.org/socket/websocket",
  reconnect_after_msec: [200, 500, 1_000, 2_000]

config :sower, Sower.Orchestration.StaleDeploymentFinalizer, interval_ms: 0
