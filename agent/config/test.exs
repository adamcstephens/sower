import Config

config :sower_agent, SocketClient,
  uri: "ws://example.org/socket/websocket",
  reconnect_after_msec: [200, 500, 1_000, 2_000]
