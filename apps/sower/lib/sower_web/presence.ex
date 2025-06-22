defmodule SowerWeb.Presence do
  use Phoenix.Presence,
    otp_app: :sower_web,
    pubsub_server: Sower.PubSub
end
