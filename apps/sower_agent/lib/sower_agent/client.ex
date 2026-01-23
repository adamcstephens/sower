defmodule SowerAgent.Client do
  use SowerAgent.ChannelClient, lobby_topic: "agent:lobby"

  require Logger

  alias SowerAgent.Scheduler
  alias SowerAgent.Storage

  def deploy(%SowerClient.Orchestration.Subscription{} = sub) do
    GenServer.cast(__MODULE__, {:deployment_request, sub})
  end

  @impl Slipstream
  def handle_cast({:deployment_request, %{sid: sid}}, socket) do
    {:ok, upgrade_request} =
      SowerClient.Orchestration.DeploymentRequest.new(%{
        subscription_sids: [sid]
      })

    {:ok, _ref} = push_message(socket, upgrade_request)

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_cast(:report_seeds, socket) do
    report = SowerAgent.Profile.collect_all_profiles()

    Logger.debug(
      msg: "Reporting seed profiles",
      profile_count: length(report.profiles)
    )

    topic = private_channel(socket)
    {:ok, _ref} = push(socket, topic, "agent:seeds:report", report)

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_cast(:sync_subscriptions, socket) do
    config_subscriptions = SowerAgent.Config.get().subscriptions
    sync_payload = %{subscriptions: Enum.map(config_subscriptions, &Map.from_struct/1)}

    topic = private_channel(socket)
    {:ok, ref} = push(socket, topic, "subscriptions:sync", sync_payload)

    subscriptions =
      case await_reply(ref) do
        {:ok, %{"subscriptions" => registered}} ->
          # Build a map of (seed_name, seed_type) -> sid for quick lookup
          sid_map =
            registered
            |> Enum.map(&SowerClient.Orchestration.Subscription.cast!/1)
            |> Map.new(&{{&1.seed_name, &1.seed_type}, &1.sid})

          # Merge server-assigned sids back into original subscriptions
          # to preserve agent-only fields like schedule and poll_on_connect
          Enum.map(config_subscriptions, fn sub ->
            case Map.get(sid_map, {sub.seed_name, sub.seed_type}) do
              nil -> nil
              sid -> %{sub | sid: sid}
            end
          end)
          |> Enum.reject(&is_nil/1)

        {:error, error} ->
          Logger.error(msg: "Failed to sync subscriptions", error: error)
          []
      end

    Scheduler.refresh_subscriptions(subscriptions)

    SowerAgent.Storage.put(:subscriptions, subscriptions)

    subscriptions
    |> Enum.filter(& &1.poll_on_connect)
    |> Enum.each(fn sub ->
      Task.Supervisor.start_child(SowerAgent.TaskSupervisor, fn ->
        deploy(sub)
      end)
    end)

    {:noreply, socket}
  end

  #
  # server
  #

  @impl Slipstream
  def init(_args) do
    do_connect()
  end

  defp do_connect() do
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
        {:ok, Map.put(socket, :active_deployments, %{})}

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
        SowerClient.AgentHello.cast!(%{
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

    cast(:sync_subscriptions)
    cast(:report_seeds)

    {:ok, assign(socket, :conn_sid, conn_sid)}
  end

  @impl Slipstream
  def handle_message(topic, "ping", %{"ref" => ref}, socket) do
    {:ok, _ref} = push(socket, topic, "pong", %{ref: ref})
    {:noreply, socket}
  end

  def handle_message(
        "agent:" <> topic,
        "deployment",
        payload,
        %{assigns: %{agent_sid: agent_sid}} = socket
      )
      when topic == agent_sid do
    case SowerClient.Orchestration.Deployment.cast(payload) do
      {:ok, deployment} ->
        Logger.debug(
          msg: "Received deployment",
          request_id: deployment.request_id,
          deployment_sid: deployment.sid
        )

        socket = put_in(socket.active_deployments[deployment.sid], deployment)
        send(self(), {:run_deployment, deployment.sid})

        {:ok, socket}

      {:error, error} ->
        Logger.error(msg: "Error casting deployment", error: error)
        {:ok, socket}
    end
  end

  def handle_message(
        "agent:" <> topic,
        "deployment:error",
        payload,
        %{assigns: %{agent_sid: agent_sid}} = socket
      )
      when topic == agent_sid do
    Logger.error(
      msg: "Deployment request failed",
      request_id: payload["request_id"],
      reason: payload["reason"]
    )

    {:ok, socket}
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

  def handle_reply(_ref, :ok, socket) do
    {:noreply, socket}
  end

  def handle_reply(ref, payload, socket) do
    Logger.debug(msg: "Received unknown reply", ref: ref, payload: payload)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_info({:run_deployment, sid}, socket) do
    case Map.get(socket.active_deployments, sid) do
      nil ->
        Logger.warning(msg: "Deployment not found", sid: sid)
        {:noreply, socket}

      deployment ->
        result = SowerAgent.Deployer.run(deployment)

        {:ok, deployment_result} =
          SowerClient.Orchestration.DeploymentResult.cast(%{
            request_id: deployment.request_id,
            deployment_sid: deployment.sid,
            result: result,
            deployed_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        {:ok, _result_ref} = push_message(socket, deployment_result)

        socket = update_in(socket.active_deployments, &Map.delete(&1, sid))

        cast(:report_seeds)
        send(self(), :check_pending_reload)

        {:noreply, socket}
    end
  end

  def handle_info(:check_pending_reload, socket) do
    if map_size(socket.active_deployments) == 0 do
      if SowerAgent.take_pending_reload(), do: reload_agent_service()
    end

    {:noreply, socket}
  end

  def private_channel(_socket) do
    "agent:#{Storage.read().agent_sid}"
  end

  def reload_agent_service do
    Logger.info(msg: "Restarting sower-agent service")

    case System.cmd(
           "busctl",
           [
             "call",
             "org.freedesktop.systemd1",
             "/org/freedesktop/systemd1",
             "org.freedesktop.systemd1.Manager",
             "RestartUnit",
             "ss",
             "sower-agent.service",
             "replace"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        Logger.debug(msg: "Successfully restarted sower-agent service")
        {:ok, output}

      {error, _code} ->
        Logger.error(msg: "Failed to restart sower-agent via busctl", error: error)
        {:error, error}
    end
  end
end
