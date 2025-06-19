defmodule SowerAgent.SocketClient do
  use Slipstream

  require Logger

  @lobby_topic "agent:lobby"

  alias SowerAgent.Storage

  #
  # client
  #

  def send(message) do
    GenServer.call(__MODULE__, message)
  end

  def send(event, params) do
    GenServer.call(__MODULE__, {event, params})
  end

  def restart() do
    GenServer.stop(__MODULE__, :shutdown)
  end

  @impl Slipstream
  def handle_call(:ping, _, socket) do
    {:ok, ref} = push(socket, "agent:lobby", "ping", %{})
    {:ok, "pong"} = await_reply(ref)
    {:reply, {:ok, :pong}, socket}
  end

  @impl Slipstream
  def handle_call(:reconnect, _, socket) do
    reconnect(socket)
  end

  @impl Slipstream
  def handle_call({event, params}, _from, socket) do
    {:ok, ref} = push(socket, "agent:#{Storage.read().agent_sid}", event, params)
    {:ok, response} = await_reply(ref)
    {:reply, {:ok, response}, socket}
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
    config = Application.fetch_env!(:sower_agent, __MODULE__)

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
  def handle_join(@lobby_topic, %{"conn_sid" => conn__sid}, socket) do
    Logger.debug(msg: "Joined channel topic", topic: @lobby_topic, conn__sid: conn__sid)

    {:ok, hello_ref} =
      push(
        socket,
        @lobby_topic,
        "agent:hello",
        SowerClient.AgentHello.new!(%{
          name: "TODO",
          local_sid: SowerAgent.Storage.read().local_sid,
          agent_sid: SowerAgent.Storage.read().agent_sid
        })
      )

    {:ok, Map.put(socket, :hello_ref, hello_ref)}
  end

  @impl Slipstream
  def handle_join("agent:" <> _sid = topic, _response, socket) do
    Logger.debug(msg: "Joined channel topic", topic: topic)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_message(topic, "ping", %{"ref" => ref}, socket) do
    {:ok, _ref} = push(socket, topic, "pong", %{ref: ref})
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_reply(
        ref,
        {:ok, %{"sid" => agent_sid} = agent},
        %{hello_ref: hello_ref} = socket
      )
      when ref == hello_ref do
    Logger.debug(msg: "Received hello reply", agent: agent)
    storage = SowerAgent.Storage.read()

    if is_nil(storage.agent_sid) do
      storage |> Map.put(:agent_sid, agent_sid) |> SowerAgent.Storage.write()
    end

    socket =
      socket
      |> join("agent:#{agent_sid}", %{local_sid: storage.local_sid})
      |> Map.delete(:hello_ref)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_reply(ref, message, socket) do
    Logger.debug(msg: "Received unknown reply", ref: ref, message: message)
    {:noreply, socket}
  end
end
