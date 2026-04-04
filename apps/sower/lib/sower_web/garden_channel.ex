defmodule SowerWeb.GardenChannel.Impl do
  defmacro handle_schema(module, func) do
    {_, _, module} = module
    module = Module.concat(module)
    event = apply(module, :event, [])

    quote do
      def handle_in(unquote(event), payload, socket) do
        handle_message(payload, unquote(module), socket, unquote(func))
      end
    end
  end
end

defmodule SowerWeb.GardenChannel do
  use Phoenix.Channel

  alias Sower.Orchestration
  alias SowerWeb.Presence
  require Logger

  import SowerWeb.GardenChannel.Impl, only: [handle_schema: 2]

  def get_assigns(garden_sid) do
    Phoenix.PubSub.broadcast(Sower.PubSub, "garden:#{garden_sid}", :ping)
  end

  @impl Phoenix.Channel
  def join("garden:lobby", message, socket), do: do_join_lobby(message, socket)
  def join("agent:lobby", message, socket), do: do_join_lobby(message, socket)

  def join("garden:" <> topic_sid = topic, params, socket),
    do: do_join_private(topic_sid, topic, params, socket)

  def join("agent:" <> topic_sid = topic, params, socket),
    do: do_join_private(topic_sid, topic, params, socket)

  def join(topic, params, socket) do
    Logger.warning(
      msg: "Unauthorized join",
      topic: topic,
      params: params,
      socket: socket
    )

    {:error, %{reason: "unauthorized"}}
  end

  defp do_join_lobby(_message, %{assigns: %{conn_sid: conn_sid}} = socket) do
    Sower.Repo.put_org_id(socket.assigns.access_token.org_id)

    Logger.debug(msg: "Channel topic joined", topic: socket.topic, conn_sid: conn_sid)

    {:ok, %{conn_sid: conn_sid}, socket}
  end

  defp do_join_private(
         topic_sid,
         topic,
         %{"local_sid" => local_sid},
         %{assigns: %{conn_sid: conn_sid}} = socket
       ) do
    Sower.Repo.put_org_id(socket.assigns.access_token.org_id)

    Logger.debug(
      msg: "Channel topic joined",
      topic: topic,
      local_sid: local_sid,
      conn_sid: conn_sid
    )

    case Orchestration.get_garden_sid(topic_sid) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      garden when is_nil(garden.local_sid) ->
        {:error, %{reason: "unauthorized"}}

      garden when garden.local_sid == local_sid ->
        send(self(), :track_presence)
        send(self(), :reconcile_deployments)
        {:ok, %{conn_sid: conn_sid}, assign(socket, :garden, garden)}

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl Phoenix.Channel
  def handle_in("ping", _, socket) do
    Logger.debug(msg: "Received ping, ponging")
    {:reply, {:ok, :pong}, socket}
  end

  def handle_in("pong", %{"ref" => _ref}, socket) do
    {:reply, :ok, socket}
  end

  # Accept both "garden:hello" and "agent:hello"
  def handle_in("garden:hello", payload, socket), do: do_handle_hello(payload, socket)
  def handle_in("agent:hello", payload, socket), do: do_handle_hello(payload, socket)

  defp do_handle_hello(payload, socket) do
    case payload
         |> normalize_hello_payload()
         |> SowerClient.GardenHello.cast!()
         |> Sower.Orchestration.get_garden(socket) do
      {:ok, garden, oauth_credentials} ->
        reply = %{
          sid: garden.sid,
          local_sid: garden.local_sid,
          oauth_credentials: oauth_credentials
        }

        Logger.debug(msg: "Replying to hello with oauth credentials", garden_sid: garden.sid)
        {:reply, {:ok, reply}, assign(socket, :garden_sid, garden.sid)}

      {:ok, garden} ->
        Logger.debug(msg: "Replying to hello", garden: garden)
        {:reply, {:ok, garden}, assign(socket, :garden_sid, garden.sid)}

      {:error, error} ->
        Logger.error(msg: "Error returning hello", error: error)
        {:reply, {:error, error}, socket}
    end
  end

  # Accept both "agent_sid" (legacy) and "garden_sid" from hello payloads
  defp normalize_hello_payload(%{"agent_sid" => sid} = payload) when is_binary(sid) do
    payload
    |> Map.delete("agent_sid")
    |> Map.put_new("garden_sid", sid)
  end

  defp normalize_hello_payload(payload), do: payload

  handle_schema(SowerClient.Seed, &Sower.Orchestration.Seed.get_by_request/1)

  handle_schema(SowerClient.Orchestration.Subscription, fn req, socket ->
    Sower.Orchestration.register_subscription(req, socket.assigns.garden.id)
  end)

  handle_schema(SowerClient.Orchestration.SubscriptionSync, fn req, socket ->
    case Sower.Orchestration.sync_subscriptions(req.subscriptions, socket.assigns.garden.id) do
      {:ok, subscriptions} ->
        {:ok, %{subscriptions: subscriptions}}

      {:error, error} ->
        {:error, error}
    end
  end)

  handle_schema(SowerClient.Orchestration.DeploymentRequest, fn req, socket ->
    case Orchestration.handle_deployment_request(
           req,
           socket.assigns.garden
         ) do
      {:ok, request_id} ->
        {:ok, %{request_id: request_id}}

      {:error, error} ->
        Logger.error(msg: "Invalid deployment request", error: error)
        {:error, error}
    end
  end)

  handle_schema(
    SowerClient.Orchestration.DeploymentStatus,
    &Sower.Orchestration.Deployment.record_deployment_status/1
  )

  handle_schema(
    SowerClient.Orchestration.DeploymentResult,
    &Sower.Orchestration.record_deployment/1
  )

  handle_schema(SowerClient.Orchestration.SeedDeploymentStatus, fn req, socket ->
    Sower.Orchestration.SeedDeployment.record_seed_status(req, socket.assigns.garden)
  end)

  handle_schema(SowerClient.Orchestration.SeedDeploymentResult, fn req, socket ->
    Sower.Orchestration.SeedDeployment.record_seed_result(req, socket.assigns.garden)
  end)

  # Accept both new and old seeds report events
  handle_schema(SowerClient.Orchestration.GardenSeedsReport, fn report, socket ->
    Orchestration.update_garden_seed_generations(report, socket.assigns.garden)
  end)

  handle_schema(SowerClient.Orchestration.AgentSeedsReport, fn report, socket ->
    # Convert legacy AgentSeedsReport to GardenSeedsReport for internal handling
    report = struct(SowerClient.Orchestration.GardenSeedsReport, Map.from_struct(report))
    Orchestration.update_garden_seed_generations(report, socket.assigns.garden)
  end)

  # Kept for backward compatibility with old gardens that still upload logs to S3.
  # New gardens send SeedDeploymentResult instead.
  # remove 0.7.0
  handle_schema(SowerClient.Storage.DeploymentLogUploadRequest, fn _req, _socket ->
    {:error, :deprecated}
  end)

  @impl Phoenix.Channel
  def handle_info(:track_presence, %Phoenix.Socket{assigns: %{garden: garden}} = socket) do
    Logger.debug(msg: "Tracking garden presence", garden_sid: garden.sid)

    {:ok, _} =
      Presence.track(self(), "garden:presence", socket.assigns.garden.sid, %{
        online_at: DateTime.utc_now()
      })

    # Also track on legacy topic for 0.7.0 LiveView compatibility
    {:ok, _} =
      Presence.track(self(), "agent:presence", socket.assigns.garden.sid, %{
        online_at: DateTime.utc_now()
      })

    {:noreply, socket}
  end

  def handle_info(
        :reconcile_deployments,
        %Phoenix.Socket{assigns: %{garden: garden}} = socket
      ) do
    Orchestration.Deployment.reconcile_deployments_on_connect(garden)
    {:noreply, socket}
  end

  def handle_info(:ping, socket) do
    ref = SowerClient.Sid.generate()
    Logger.debug(msg: "Sending ping", ref: ref, component: :server, topic: socket.topic)
    push(socket, "ping", %{ref: ref})
    {:noreply, socket}
  end

  # provide a standard way of casting the schemas and handling the errors
  defp handle_message(payload, schema, socket, fun) do
    with {:ok, params} <- schema.cast(payload),
         {:ok, result} <- apply_handler(fun, params, socket) do
      {:reply, {:ok, result}, socket}
    else
      nil ->
        {:reply, {:error, :not_found}, socket}

      {:error, _} = error ->
        Logger.error(msg: "Channel handler error", error: error, topic: socket.topic)
        {:reply, error, socket}
    end
  end

  defp apply_handler(fun, params, socket) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 1} ->
        fun.(params)

      {:arity, 2} ->
        fun.(params, socket)

      {:arity, arity} ->
        raise ArgumentError, "Channel handler arity #{arity} is not supported"
    end
  end
end
