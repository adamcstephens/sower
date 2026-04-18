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

  def join("garden:" <> topic_sid = topic, params, socket),
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
         params,
         %{assigns: %{conn_sid: conn_sid, access_token: access_token}} = socket
       ) do
    Sower.Repo.put_org_id(access_token.org_id)

    Logger.debug(
      msg: "Channel topic joined",
      topic: topic,
      conn_sid: conn_sid
    )

    case authorize_private_join(topic_sid, params, access_token) do
      {:ok, garden} ->
        send(self(), :track_presence)
        send(self(), :reconcile_deployments)
        {:ok, %{conn_sid: conn_sid}, assign(socket, :garden, garden)}

      :error ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  defp authorize_private_join(topic_sid, _params, %Sower.GardenAuth.Context{} = context) do
    case Orchestration.get_garden_sid(topic_sid) do
      %{id: id} = garden when id == context.garden_id -> {:ok, garden}
      _ -> :error
    end
  end

  defp authorize_private_join(_topic_sid, _params, _access_token), do: :error

  @impl Phoenix.Channel
  def handle_in("ping", _, socket) do
    Logger.debug(msg: "Received ping, ponging")
    {:reply, {:ok, :pong}, socket}
  end

  def handle_in("pong", %{"ref" => _ref}, socket) do
    {:reply, :ok, socket}
  end

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
      {:ok, request_id, _pid} ->
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

  handle_schema(SowerClient.Orchestration.GardenSeedsReport, fn report, socket ->
    Orchestration.update_garden_seed_generations(report, socket.assigns.garden)
  end)

  handle_schema(SowerClient.Orchestration.GardenReport, fn report, socket ->
    Orchestration.update_garden_report(socket.assigns.garden, report)
  end)

  @impl Phoenix.Channel
  def handle_info(:track_presence, %Phoenix.Socket{assigns: %{garden: garden}} = socket) do
    Logger.debug(msg: "Tracking garden presence", garden_sid: garden.sid)

    {:ok, _} =
      Presence.track(self(), "garden:presence", socket.assigns.garden.sid, %{
        online_at: DateTime.utc_now()
      })

    {:noreply, socket}
  end

  def handle_info(
        :reconcile_deployments,
        %Phoenix.Socket{assigns: %{garden: garden}} = socket
      ) do
    Task.Supervisor.start_child(Sower.TaskSupervisor, fn ->
      Sower.Repo.put_org_id(garden.org_id)
      Orchestration.Deployment.reconcile_deployments_on_connect(garden)
    end)

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
