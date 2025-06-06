import Config

config :sower_client, SowerClient.SocketClient,
  uri: "ws://localhost:7150/client/websocket",
  reconnect_after_msec: [200, 500, 1_000, 2_000]
