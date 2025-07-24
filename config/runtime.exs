import Config

if config_env() == :dev do
  SowerAgent.Config.load(%{
    access_token_file: Path.expand("../.dev-api-token", __DIR__),
    endpoint: "http://localhost:7150",
    state_directory: Path.expand("../_build", __DIR__),
    subscriptions: [
      %{name: "deck", seed_type: "nixos"},
      %{name: "deck", seed_type: "home-manager"}
    ]
  })
end

if config_env() != :test do
  Sower.Config.load()
end
