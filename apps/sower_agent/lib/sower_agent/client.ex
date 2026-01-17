defmodule SowerAgent.Client do
  use SowerAgent.ChannelClient, lobby_topic: "agent:lobby"

  require Logger

  alias SowerAgent.Storage

  def deploy(%SowerClient.Orchestration.Subscription{} = sub) do
    call({:deployment_request, sub})
  end

  def handle_call({:deployment_request, %{sid: sid}}, _from, socket) do
    {:ok, upgrade_request} =
      SowerClient.Orchestration.DeploymentRequest.new(%{
        subscription_sids: [sid]
      })

    {:ok, ref} = push_message(socket, upgrade_request)

    {:reply, :ok, Map.put(socket, :upgrade_ref, ref)}
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

    # TODO prune old schedules
    :ok = Enum.each(subscriptions, &start_schedule/1)

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
    case verify_auth() do
      {:ok, token_info} ->
        Logger.info(msg: "Authenticated", description: token_info.description)
        do_connect()

      {:error, reason} ->
        Logger.error(msg: "Authentication failed", reason: reason)
        :ignore
    end
  end

  defp verify_auth() do
    SowerClient.Auth.verify()
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

    case response do
      {:ok, response} ->
        case SowerClient.Orchestration.Deployment.cast(response) do
          {:ok, deployment} ->
            Logger.debug(
              msg: "Received deployment",
              request_id: deployment.request_id,
              deployment_sid: deployment.sid
            )

            result = SowerAgent.Deployer.run(deployment)

            {:ok, result} =
              SowerClient.Orchestration.DeploymentResult.cast(%{
                request_id: deployment.request_id,
                deployment_sid: deployment.sid,
                result: result,
                deployed_at: DateTime.utc_now() |> DateTime.to_iso8601()
              })

            {:ok, _result_ref} = push_message(socket, result)

            if SowerAgent.take_pending_reload(), do: reload_agent_service()

          {:error, error} ->
            Logger.error(msg: "Error handling deployment", error: error)
        end

      {:error, error} ->
        Logger.error(msg: "Error returned from server", error: error)
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

  defp start_schedule(%SowerClient.Orchestration.Subscription{
         sid: sid,
         schedule: schedule
       })
       when not is_nil(sid) and not is_nil(schedule) do
    case Crontab.CronExpression.Parser.parse(schedule) do
      {:ok, cron} ->
        SowerAgent.Scheduler.new_job()
        |> Quantum.Job.set_name(:"subsched_#{sid}")
        |> Quantum.Job.set_schedule(cron)
        |> Quantum.Job.set_task(fn ->
          subscriptions = SowerAgent.Storage.read().subscriptions || []

          case Enum.find(subscriptions, &(&1.sid == sid)) do
            nil ->
              Logger.warning(
                msg: "Subscription not found for scheduled deployment",
                subscription_sid: sid
              )

            subscription ->
              Logger.info(
                msg: "Running scheduled deployment",
                subscription_sid: sid,
                schedule: schedule
              )

              SowerAgent.Client.deploy(subscription)
          end
        end)
        |> SowerAgent.Scheduler.add_job()

      {:error, error} ->
        Logger.error(
          msg: "Failed to parse schedule",
          error: error,
          schedule: schedule,
          subscription_sid: sid
        )

        nil
    end
  end

  defp start_schedule(_), do: nil

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
