defmodule SowerAgent.Client do
  use SowerAgent.ChannelClient, lobby_topic: "agent:lobby"

  require Logger

  alias SowerAgent.Storage

  def handle_call({:deployment_request, %{sid: sid}}, _from, socket) do
    {:ok, upgrade_request} =
      SowerClient.Schemas.Orchestration.DeploymentRequest.new(%{
        subscription_sids: [sid]
      })

    {:ok, ref} = push_message(socket, upgrade_request)

    {:reply, :ok, Map.put(socket, :upgrade_ref, ref)}
  end

  @impl Slipstream
  def handle_cast(:register_subscriptions, socket) do
    subscriptions =
      SowerAgent.Config.get().subscriptions
      |> Enum.map(fn agent_sub ->
        # Convert to client schema before sending to server
        client_sub = SowerAgent.Subscription.to_client_schema(agent_sub)

        with {:ok, ref} <- push_message(socket, client_sub),
             {:ok, response} <- await_reply(ref),
             {:ok, registered} <-
               SowerClient.Schemas.Orchestration.Subscription.cast(response) do
          Logger.debug(registered)

          # Merge server-assigned sid back into agent subscription
          %{agent_sub | sid: registered.sid}
        else
          {:error, error} ->
            Logger.error(
              msg: "Failed to register subscription",
              error: error,
              subscription: agent_sub
            )

            nil

          :error ->
            Logger.error(
              msg: "Failed to register subscription with unknown error",
              subscription: agent_sub
            )

            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    :ok = Enum.each(subscriptions, &SowerAgent.Subscription.start_schedule/1)

    SowerAgent.Storage.put(:subscriptions, subscriptions)

    {:noreply, socket}
  end

  #
  # server
  #

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
  def handle_join(@lobby_topic, %{"conn_sid" => conn_sid}, socket) do
    Logger.info(msg: "Joined channel topic", topic: @lobby_topic, conn_sid: conn_sid)

    {:ok, hello_ref} =
      push_message(
        socket,
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

    # TODO error handling
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

        {:ok, _result_ref} = push_message(socket, result)

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

  def private_channel(_socket) do
    "agent:#{Storage.read().agent_sid}"
  end
end
