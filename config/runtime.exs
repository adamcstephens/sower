import Config

if config_env() == :dev do
  config :garden, Garden.Scheduler, timezone: Garden.Scheduler.get_timezone()

  Garden.Config.load(%{
    access_token_file: Path.expand("../.dev-api-token", __DIR__),
    endpoint: "http://localhost:7150",
    state_directory: Path.expand("../_build", __DIR__)
  })

  Sower.Config.load()
end

if config_env() == :test do
  if Code.loaded?(Garden.Config) do
    Garden.Config.load(
      %{
        state_directory: Path.expand("../_build", __DIR__),
        subscriptions: [
          %{seed_name: "test1", seed_type: "nixos"},
          %{seed_name: "test1", seed_type: "home-manager"}
        ]
      },
      skip_config_file: true,
      validate: false
    )
  end

  if Code.loaded?(SowerCli.Config) do
    SowerCli.Config.load(skip_config_file: true)
  end
end
