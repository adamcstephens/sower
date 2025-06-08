defmodule SowerClient.SocketClient do
  use Slipstream

  require Logger

  @lobby_topic "client:lobby"

  #
  # client
  #

  def send(message) do
    GenServer.call(__MODULE__, message)
  end

  @impl Slipstream
  def handle_call(:ping, _, %{assigns: %{sid: sid}} = socket) do
    {:ok, ref} = push(socket, "client:#{sid}", "ping", %{})
    {:ok, "pong"} = await_reply(ref)
    {:reply, {:ok, :pong}, socket}
  end

  @impl Slipstream
  def handle_call(request, from, socket) do
    Logger.debug(msg: "Unsupported call", request: request, from: from)
    {:reply, {:error, :unsupported_request}, socket}
  end

  #
  # server
  #

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
    {:ok, join(socket, @lobby_topic)}
  end

  @impl Slipstream
  def handle_reply(ref, message, %{assigns: %{sid: sid}} = socket) do
    Logger.debug(msg: "Received reply", ref: ref, message: message, sid: sid)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_join(@lobby_topic, %{"sid" => sid}, socket) do
    Logger.debug(msg: "Joined channel topic", topic: @lobby_topic)

    socket = socket |> assign(:sid, sid) |> join("client:#{sid}")

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join("client:" <> _sid = topic, _response, socket) do
    Logger.debug(msg: "Joined channel topic", topic: topic)
    {:ok, socket}
  end
end
