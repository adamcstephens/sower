import Config

config :sower_agent, SowerAgent.SocketClient,
  uri: "ws://localhost:7150/agent/websocket",
  reconnect_after_msec: [200, 500, 1_000, 2_000]

config :sower_agent, SowerAgent.Storage, file: "./data/storage.etf"

config :exsync,
  reload_callback: {SowerAgent.SocketClient, :restart, []}
