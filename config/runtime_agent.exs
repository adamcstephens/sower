import Config

config :sower_agent, :config, SowerAgent.Config.load(config_env())
