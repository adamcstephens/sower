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
  def handle_connect(socket) do
    Logger.info(
      msg: "Connected to websocket",
      authority: socket.channel_config.uri.authority,
      path: socket.channel_config.uri.path
    )

    socket = assign(socket, :reconnect_counter, 0)
    {:ok, join(socket, @lobby_topic)}
  end

  @impl Slipstream
  def init(_args) do
    case do_connect() do
      {:ok, socket} ->
        {:ok, Map.put(socket, :active_deployments, %{})}

      {:error, reason} ->
        Logger.warning(
          msg: "Initial connection failed, will retry",
          error: inspect(reason)
        )

        socket =
          new_socket()
          |> Map.put(:active_deployments, %{})
          |> assign(:reconnect_counter, 0)

        {:ok, schedule_reconnect(socket)}
    end
  end

  @impl Slipstream
  def handle_disconnect({:error, {:upgrade_failure, %{status_code: status}}} = reason, socket)
      when status in [403, 401] do
    Logger.warning(
      msg: "Server rejected connection, invalidating cached token",
      status: status,
      reason: inspect(reason)
    )

    invalidate_cached_token()
    {:ok, schedule_reconnect(socket)}
  end

  def handle_disconnect(reason, socket) do
    Logger.warning(msg: "Disconnected from server socket", reason: inspect(reason))
    {:ok, schedule_reconnect(socket)}
  end

  defp invalidate_cached_token do
    storage = Storage.read()

    case storage do
      %{oauth_credentials: %{access_token: _} = creds} ->
        updated_creds = Map.drop(creds, [:access_token, :token_issued_at, :expires_in])
        storage |> Map.put(:oauth_credentials, updated_creds) |> Storage.write()

      _ ->
        :ok
    end
  end

  defp schedule_reconnect(socket) do
    counter = Map.get(socket.assigns, :reconnect_counter, 0)

    backoff_times =
      Application.get_env(__MODULE__, :reconnect_after_msec, [200, 500, 1_000, 2_000])

    delay = Enum.at(backoff_times, counter, List.last(backoff_times))

    Logger.info(msg: "Scheduling reconnect", delay_ms: delay, attempt: counter + 1)
    Process.send_after(self(), :attempt_reconnect, delay)

    assign(socket, :reconnect_counter, counter + 1)
  end

  defp do_connect(socket \\ nil) do
    with {:ok, config} <- build_connect_config(),
         {:ok, socket} <-
           if(socket, do: connect(socket, config), else: connect(config)) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_connect_config do
    config = Application.get_all_env(__MODULE__)
    uri = Keyword.get(config, :uri)

    case resolve_connect_token() do
      {:ok, token} ->
        Logger.info(msg: "Connecting to server socket", endpoint: uri)

        auth_header = {"x-auth-token", token}
        uri = URI.to_string(uri)

        connect_config =
          config
          |> Keyword.put(:uri, uri)
          |> Keyword.update(:headers, [auth_header], fn headers ->
            [auth_header | headers]
          end)

        {:ok, connect_config}

      {:error, reason} ->
        Logger.warning(msg: "Could not resolve connect token", reason: inspect(reason))
        {:error, reason}
    end
  end

  defp resolve_connect_token do
    storage = Storage.read()

    case storage do
      %{
        oauth_credentials: %{
          access_token: token,
          token_issued_at: issued_at,
          expires_in: expires_in
        },
        private_key_pem: private_key_pem
      }
      when is_binary(token) and is_binary(private_key_pem) ->
        if token_expired?(issued_at, expires_in) do
          try_reauthenticate_or_reregister(storage)
        else
          Logger.debug(msg: "Using stored Boruta access token")
          {:ok, "boruta:#{token}"}
        end

      %{
        oauth_credentials: %{client_id: client_id},
        private_key_pem: private_key_pem
      }
      when is_binary(client_id) and is_binary(private_key_pem) ->
        try_reauthenticate_or_reregister(storage)

      _ ->
        try_http_registration(storage)
    end
  end

  defp try_reauthenticate_or_reregister(storage) do
    case try_reauthenticate(storage) do
      {:ok, _} = ok ->
        ok

      {:error, reason} ->
        Logger.warning(
          msg: "Reauthentication failed, clearing credentials and re-registering",
          garden_sid: get_in(storage, [:garden_sid]),
          reason: inspect(reason)
        )

        storage =
          storage
          |> Map.delete(:garden_sid)
          |> Map.delete(:oauth_credentials)

        try_http_registration(storage)
    end
  end

  defp token_expired?(issued_at, expires_in)
       when is_integer(issued_at) and is_integer(expires_in) do
    System.system_time(:second) >= issued_at + expires_in
  end

  defp token_expired?(_, _), do: true

  defp try_reauthenticate(%{
         oauth_credentials: %{client_id: client_id},
         private_key_pem: private_key_pem
       })
       when is_binary(client_id) and is_binary(private_key_pem) do
    case Garden.Auth.request_token(client_id, private_key_pem) do
      {:ok, token_response} ->
        storage = Storage.read()

        updated_creds =
          (storage.oauth_credentials || %{})
          |> Map.merge(%{
            access_token: token_response.access_token,
            expires_in: token_response.expires_in,
            token_issued_at: System.system_time(:second)
          })

        storage |> Map.put(:oauth_credentials, updated_creds) |> Storage.write()
        Logger.debug(msg: "Reauthenticated via JWT assertion")
        {:ok, "boruta:#{token_response.access_token}"}

      {:error, reason} ->
        {:error, {:reauthentication_failed, reason}}
    end
  end

  defp try_reauthenticate(_), do: {:error, :no_credentials}

  defp try_http_registration(storage) do
    config = Garden.Config.get()
    {public_key_pem, storage} = Garden.Auth.ensure_keypair(storage)

    req =
      Req.new(
        base_url: "#{config.endpoint}/api/v1",
        auth: {:bearer, config.access_token},
        retry: false
      )

    case SowerClient.Registration.register(req, config.name, public_key_pem) do
      {:ok, %{garden_sid: garden_sid, client_id: client_id}} ->
        Logger.info(msg: "Registered via HTTP", garden_sid: garden_sid, client_id: client_id)

        oauth_creds = %{client_id: client_id}
        storage = Map.merge(storage, %{garden_sid: garden_sid, oauth_credentials: oauth_creds})

        case Garden.Auth.request_token(client_id, storage.private_key_pem) do
          {:ok, token_response} ->
            updated_creds =
              Map.merge(oauth_creds, %{
                access_token: token_response.access_token,
                expires_in: token_response.expires_in,
                token_issued_at: System.system_time(:second)
              })

            storage |> Map.put(:oauth_credentials, updated_creds) |> Storage.write()
            {:ok, "boruta:#{token_response.access_token}"}

          {:error, reason} ->
            Storage.write(storage)
            {:error, {:token_request_failed, reason}}
        end

      {:error, reason} ->
        Logger.warning(msg: "HTTP registration failed", reason: inspect(reason))
        {:error, {:registration_failed, reason}}
    end
  end

  defp schedule_reauthentication(socket, %{expires_in: expires_in})
       when is_integer(expires_in) do
    # Reauthenticate at 80% of TTL
    reauth_ms = trunc(expires_in * 0.8 * 1000)
    timer_ref = Process.send_after(self(), :reauthenticate, reauth_ms)

    Logger.debug(msg: "Scheduled reauthentication", reauth_in_seconds: div(reauth_ms, 1000))
    assign(socket, :reauth_timer, timer_ref)
  end

  defp schedule_reauthentication(socket, _), do: socket

  defp maybe_schedule_existing_reauth(socket, %{expires_in: _} = creds) do
    schedule_reauthentication(socket, creds)
  end

  defp maybe_schedule_existing_reauth(socket, _), do: socket

  @impl Slipstream
  def handle_join(@lobby_topic, %{"conn_sid" => conn_sid}, socket) do
    storage = Garden.Storage.read()
    garden_sid = storage.garden_sid

    Logger.info(msg: "Joined lobby, joining private channel", garden_sid: garden_sid)

    socket =
      socket
      |> assign(:conn_sid, conn_sid)
      |> assign(:garden_sid, garden_sid)
      |> maybe_schedule_existing_reauth(storage.oauth_credentials)
      |> join("garden:#{garden_sid}", %{local_sid: storage.local_sid})

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

  def handle_info(:attempt_reconnect, socket) do
    case do_connect(socket) do
      {:ok, socket} ->
        {:noreply, socket}

      {:error, reason} ->
        Logger.warning(msg: "Reconnect attempt failed", error: inspect(reason))
        {:noreply, schedule_reconnect(socket)}
    end
  end

  def handle_info(:reauthenticate, socket) do
    storage = Storage.read()

    case storage do
      %{oauth_credentials: %{client_id: client_id}, private_key_pem: private_key_pem}
      when is_binary(client_id) and is_binary(private_key_pem) ->
        case Garden.Auth.request_token(client_id, private_key_pem) do
          {:ok, token_response} ->
            updated_creds =
              storage.oauth_credentials
              |> Map.merge(%{
                access_token: token_response.access_token,
                expires_in: token_response.expires_in,
                token_issued_at: System.system_time(:second)
              })

            storage |> Map.put(:oauth_credentials, updated_creds) |> Storage.write()
            Logger.info(msg: "Reauthenticated via JWT assertion")
            {:noreply, schedule_reauthentication(socket, updated_creds)}

          {:error, _} ->
            Logger.warning(msg: "Reauthentication failed, retrying in 60s")
            Process.send_after(self(), :reauthenticate, 60_000)
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
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
