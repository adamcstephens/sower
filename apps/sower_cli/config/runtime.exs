import Config

config :req, default_options: [plugins: [SowerClient.Proxy]]

if config_env() != :test do
  SowerCli.Config.load()
end
