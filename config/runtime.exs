import Config

if config_env() != :test do
  config :sower_agent, config: SowerAgent.Config.load(config_env())
  Sower.Config.load()
end
