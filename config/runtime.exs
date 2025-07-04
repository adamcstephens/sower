import Config

if config_env() != :test do
  config :sower_agent, config: SowerAgent.Config.load()
  Sower.Config.load()
end
