import Config

config :sower_agent, SowerAgent.Scheduler, timezone: SowerAgent.Scheduler.get_timezone()

SowerAgent.Config.load()
