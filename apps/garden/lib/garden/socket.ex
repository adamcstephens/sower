defmodule Garden.Socket do
  use Garden.ChannelClient, lobby_topic: "garden:lobby"

  require Logger

  alias Garden.Scheduler
  alias Garden.Socket.Lifecycle
  alias Garden.Storage
  alias SowerClient.Orchestration.DeploymentStatus
  alias SowerClient.Orchestration.SeedDeploymentStatus

  def deploy(%SowerClient.Orchestration.Subscription{} = sub, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    GenServer.cast(__MODULE__, {:deployment_request, sub, force?})
  end

  @impl Slipstream
  def handle_cast({:deployment_request, %{sid: sid}, force?}, socket) do
    {:ok, upgrade_request} = Lifecycle.build_deployment_request(sid, force?)
    {:ok, _ref} = push_message(socket, upgrade_request)

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_cast(:report_seeds, socket) do
    subscriptions = Map.get(Storage.read(), :subscriptions, [])

    case Lifecycle.build_seed_report(subscriptions) do
      :no_profiles ->
        Logger.debug(
          msg: "No profiles found for any targets",
          subscription_count: length(subscriptions)
        )

      {:report, report} ->
        Logger.debug(
          msg: "Reporting seed profiles",
          profile_count: length(report.profiles),
          subscription_count: length(subscriptions)
        )

        {:ok, _ref} = push(socket, private_channel(socket), "garden:seeds:report", report)
    end

    {:noreply, socket}
  end

  @impl Slipstream
  def handle_cast({:seed_status, %SeedDeploymentStatus{} = status}, socket) do
    {:ok, _} = push(socket, private_channel(socket), SeedDeploymentStatus.event(), status)
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_cast(:sync_subscriptions, socket) do
    config_subscriptions = Garden.Config.get().subscriptions
    tz = Scheduler.get_timezone()

    config_subscriptions =
      Enum.map(config_subscriptions, fn sub ->
        if sub.schedule, do: %{sub | timezone: tz}, else: sub
      end)

    sync_payload = %{subscriptions: Enum.map(config_subscriptions, &Map.from_struct/1)}

    topic = private_channel(socket)
    {:ok, ref} = push(socket, topic, "subscriptions:sync", sync_payload)

    subscriptions =
      case await_reply(ref) do
        {:ok, %{"subscriptions" => registered}} ->
          Lifecycle.merge_subscriptions(config_subscriptions, registered)

        {:error, error} ->
          Logger.error(msg: "Failed to sync subscriptions", error: error)
          []
      end

    Scheduler.refresh_subscriptions(subscriptions)
    Garden.Storage.put(:subscriptions, subscriptions)

    Lifecycle.poll_on_connect_subscriptions(subscriptions)
    |> Enum.each(fn sub ->
      Task.Supervisor.start_child(Garden.TaskSupervisor, fn ->
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
        "token=#{Base.encode64(Application.fetch_env!(:garden, :config).access_token)}"
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
        SowerClient.GardenHello.cast!(%{
          name: Garden.Config.get().name,
          local_sid: Garden.Storage.read().local_sid,
          garden_sid: Garden.Storage.read().garden_sid
        })
      )

    socket =
      socket
      |> assign(:hello_ref, hello_ref)
      |> assign(:conn_sid, conn_sid)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join("garden:" <> _sid = topic, %{"conn_sid" => conn_sid}, socket) do
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
        "garden:" <> topic,
        "deployment",
        payload,
        %{assigns: %{garden_sid: garden_sid}} = socket
      )
      when topic == garden_sid do
    case SowerClient.Orchestration.Deployment.cast(payload) do
      {:ok, deployment} ->
        case Lifecycle.receive_deployment(deployment, socket.active_deployments) do
          {:enqueue, active_deployments} ->
            Logger.debug(
              msg: "Received deployment",
              request_id: deployment.request_id,
              deployment_sid: deployment.sid
            )

            send(self(), {:run_deployment, deployment.sid})
            {:ok, %{socket | active_deployments: active_deployments}}

          :duplicate ->
            Logger.debug(
              msg: "Ignoring duplicate deployment event",
              request_id: deployment.request_id,
              deployment_sid: deployment.sid
            )

            {:ok, socket}

          :skipped ->
            Logger.info(
              msg: "Deployment skipped by server",
              request_id: deployment.request_id,
              deployment_sid: deployment.sid
            )

            {:ok, socket}
        end

      {:error, error} ->
        Logger.error(msg: "Error casting deployment", error: error)
        {:ok, socket}
    end
  end

  def handle_message(
        "garden:" <> topic,
        "deployment:error",
        payload,
        %{assigns: %{garden_sid: garden_sid}} = socket
      )
      when topic == garden_sid do
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
        {:ok, %{"sid" => garden_sid} = reply},
        socket
      )
      when ref == socket.assigns.hello_ref do
    Logger.debug(msg: "Received hello reply", garden: reply)
    storage = Garden.Storage.read()

    {:join, garden_sid, persist?: persist?} =
      Lifecycle.process_hello_reply(garden_sid, storage.garden_sid)

    if persist? do
      storage |> Map.put(:garden_sid, garden_sid) |> Garden.Storage.write()
    end

    socket =
      socket
      |> join("garden:#{garden_sid}", %{local_sid: storage.local_sid})
      |> Map.put(
        :assigns,
        socket.assigns |> Map.delete(:hello_ref) |> Map.put(:garden_sid, garden_sid)
      )

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
    case Lifecycle.lookup_deployment(sid, socket.active_deployments) do
      :not_found ->
        Logger.warning(msg: "Deployment not found", sid: sid)
        {:noreply, socket}

      {:ok, deployment} ->
        {:ok, _} =
          push_message(
            socket,
            DeploymentStatus.cast!(%{
              deployment_sid: deployment.sid,
              status: :acknowledged
            })
          )

        Task.Supervisor.start_child(Garden.TaskSupervisor, fn ->
          result =
            try do
              Garden.Deployer.run(deployment)
            rescue
              error ->
                Logger.error(
                  msg: "Deployment task crashed",
                  deployment_sid: deployment.sid,
                  error: Exception.format(:error, error, __STACKTRACE__)
                )

                :failure
            catch
              kind, reason ->
                Logger.error(
                  msg: "Deployment task crashed",
                  deployment_sid: deployment.sid,
                  kind: inspect(kind),
                  reason: inspect(reason)
                )

                :failure
            end

          send(__MODULE__, {:deployment_completed, deployment.sid, result})
        end)

        {:noreply, socket}
    end
  end

  def handle_info({:deployment_completed, sid, result}, socket) do
    case Lifecycle.complete_deployment(sid, result, socket.active_deployments) do
      :not_found ->
        Logger.warning(msg: "Deployment not found during completion", sid: sid)
        {:noreply, socket}

      {:ok, deployment_result, active_deployments} ->
        {:ok, _result_ref} = push_message(socket, deployment_result)

        cast(:report_seeds)
        send(self(), :check_pending_reload)

        {:noreply, %{socket | active_deployments: active_deployments}}
    end
  end

  def handle_info(:check_pending_reload, socket) do
    if Lifecycle.should_reload?(socket.active_deployments, Garden.take_pending_reload()) do
      reload_garden_service()
    end

    {:noreply, socket}
  end

  def private_channel(_socket) do
    "garden:#{Storage.read().garden_sid}"
  end

  def reload_garden_service do
    Logger.info(msg: "Restarting sower-garden service")

    case System.cmd(
           "busctl",
           [
             "call",
             "org.freedesktop.systemd1",
             "/org/freedesktop/systemd1",
             "org.freedesktop.systemd1.Manager",
             "RestartUnit",
             "ss",
             "sower-garden.service",
             "replace"
           ],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        Logger.debug(msg: "Successfully restarted sower-garden service")
        {:ok, output}

      {error, _code} ->
        Logger.error(msg: "Failed to restart sower-garden via busctl", error: error)
        {:error, error}
    end
  end
end
