defmodule SowerClient.SocketClient do
  use Slipstream

  require Logger

  @topic "client:lobby"

  def start_link(args) do
    Slipstream.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Slipstream
  def init(_args) do
    config = Application.fetch_env!(:sower_client, __MODULE__)

    case connect(config) do
      {:ok, socket} ->
        Logger.debug(msg: "Connecting")
        {:ok, socket}

      {:error, reason} ->
        Logger.error(
          "Could not start #{__MODULE__} because of " <>
            "validation failure: #{inspect(reason)}"
        )

        :ignore
    end
  end

  @impl Slipstream
  def handle_connect(socket) do
    Logger.debug(msg: "Connected")
    {:ok, join(socket, @topic)}
  end
end
