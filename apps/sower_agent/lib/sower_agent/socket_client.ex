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

  def cast(event) when is_atom(event) do
    GenServer.cast(__MODULE__, event)
  end

  def cast(event, params) do
    GenServer.cast(__MODULE__, {event, params})
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

  def handle_call(
        {:deployment_request, subscription = %SowerClient.Schemas.Orchestration.Subscription{}},
        _from,
        socket
      ) do
    {:ok, upgrade_request} =
      SowerClient.Schemas.Orchestration.DeploymentRequest.new(%{
        subscription_sids: [subscription.sid]
      })

    {:ok, ref} = push(socket, private_channel(), "deployment:request", upgrade_request)

    {:reply, :ok, Map.put(socket, :upgrade_ref, ref)}
  end

  def handle_call({event, params}, _from, socket) do
    {:ok, ref} = push(socket, private_channel(), event, params)
    {:reply, await_reply(ref), socket}
  end

  def handle_call(request, from, socket) do
    Logger.error(msg: "Unsupported call", request: request, from: from)
    {:reply, {:error, :unsupported_request}, socket}
  end

  @impl Slipstream
  def handle_cast({event, params}, socket) do
    {:ok, _} = push(socket, private_channel(), event, params)
    {:noreply, socket}
  end

  def handle_cast(:register_subscriptions, socket) do
    subscriptions =
      SowerAgent.Config.get().subscriptions
      |> Enum.map(fn sub ->
        with {:ok, ref} <- push(socket, private_channel(), "subscription:register", sub),
             {:ok, subscription} <- await_reply(ref),
             {:ok, subscription} <-
               SowerClient.Schemas.Orchestration.Subscription.cast(subscription) do
          Logger.debug(subscription)
          subscription
        else
          {:error, error} ->
            Logger.error(msg: "Failed to register subscription", error: error, subscription: sub)
            nil

          :error ->
            Logger.error(
              msg: "Failed to register subscription with unknown error",
              subscription: sub
            )

            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    SowerAgent.Storage.put(:subscriptions, subscriptions)

    {:noreply, socket}
  end

  #
  # server
  #

  def start_link(args) do
    Slipstream.start_link(__MODULE__, args, name: __MODULE__)
  end

  @impl Slipstream
  def init(_args) do
    config = Application.get_all_env(__MODULE__)

    uri =
      config
      |> Keyword.get(:uri)
      |> Map.put(
        :query,
        "token=#{Base.encode64(Application.fetch_env!(:sower_agent, :config).access_token)}"
      )
      |> URI.to_string()

    config = Keyword.put(config, :uri, uri)

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
    Logger.info(
      msg: "Connected to websocket",
      authority: socket.channel_config.uri.authority,
      path: socket.channel_config.uri.path
    )

    {:ok, join(socket, @lobby_topic)}
  end

  @impl Slipstream
  def handle_join(@lobby_topic, %{"conn_sid" => conn_sid}, socket) do
    Logger.info(msg: "Joined channel topic", topic: @lobby_topic, conn_sid: conn_sid)

    {:ok, hello_ref} =
      push(
        socket,
        @lobby_topic,
        "agent:hello",
        SowerClient.Schemas.AgentHello.cast!(%{
          name: SowerAgent.Config.get().name,
          local_sid: SowerAgent.Storage.read().local_sid,
          agent_sid: SowerAgent.Storage.read().agent_sid
        })
      )

    socket =
      socket
      |> assign(:hello_ref, hello_ref)
      |> assign(:conn_sid, conn_sid)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join("agent:" <> _sid = topic, %{"conn_sid" => conn_sid}, socket) do
    Logger.info(msg: "Joined channel topic", topic: topic, conn_sid: conn_sid)

    cast(:register_subscriptions)

    {:ok, assign(socket, :conn_sid, conn_sid)}
  end

  @impl Slipstream
  def handle_message(topic, "ping", %{"ref" => ref}, socket) do
    {:ok, _ref} = push(socket, topic, "pong", %{ref: ref})
    {:noreply, socket}
  end

  def handle_message(topic, message, _params, socket) do
    Logger.debug(msg: "Received unknown message", topic: topic, message: message)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_reply(
        ref,
        {:ok, %{"sid" => agent_sid} = agent},
        socket
      )
      when ref == socket.assigns.hello_ref do
    Logger.debug(msg: "Received hello reply", agent: agent)
    storage = SowerAgent.Storage.read()

    if storage.agent_sid != agent_sid do
      storage |> Map.put(:agent_sid, agent_sid) |> SowerAgent.Storage.write()
    end

    socket =
      socket
      |> join("agent:#{agent_sid}", %{local_sid: storage.local_sid})
      |> Map.put(:assigns, Map.delete(socket.assigns, :hello_ref))

    {:ok, socket}
  end

  # TODO: add multi-upgrade async support
  # currently is last deploy wins
  def handle_reply(ref, response, %{upgrade_ref: ref} = socket) do
    socket = Map.delete(socket, :upgrade_ref)

    {:ok, response} = response

    case SowerClient.Schemas.Orchestration.Deployment.cast(response) do
      {:ok, deployment} ->
        Logger.debug(
          msg: "Received deployment",
          request_id: deployment.request_id,
          deployment_sid: deployment.sid
        )

        result = SowerAgent.Deployer.run(deployment)

        {:ok, result} =
          SowerClient.Schemas.Orchestration.DeploymentResult.cast(%{
            request_id: deployment.request_id,
            deployment_sid: deployment.sid,
            result: result,
            deployed_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        {:ok, _result_ref} =
          push(
            socket,
            private_channel(),
            "deployment:result",
            result
          )

      {:error, error} ->
        Logger.error(msg: "Error handling deployment", error: error)
    end

    {:ok, socket}
  end

  def handle_reply(_ref, :ok, socket) do
    {:noreply, socket}
  end

  def handle_reply(ref, payload, socket) do
    Logger.debug(msg: "Received unknown reply", ref: ref, payload: payload)
    {:noreply, socket}
  end

  defp private_channel() do
    "agent:#{Storage.read().agent_sid}"
  end
end
