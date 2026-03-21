import Config

config :garden, Garden.Scheduler, timezone: Garden.Scheduler.get_timezone()

Garden.Config.load()
