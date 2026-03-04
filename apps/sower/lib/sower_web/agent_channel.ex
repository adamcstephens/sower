defmodule SowerWeb.AgentChannel.Impl do
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

defmodule SowerWeb.AgentChannel do
  use Phoenix.Channel

  alias Sower.Orchestration
  alias SowerWeb.Presence
  require Logger

  import SowerWeb.AgentChannel.Impl, only: [handle_schema: 2]

  def get_assigns(agent_sid) do
    Phoenix.PubSub.broadcast(Sower.PubSub, "agent:#{agent_sid}", :ping)
  end

  @impl Phoenix.Channel
  def join("agent:lobby", _message, %{assigns: %{conn_sid: conn_sid}} = socket) do
    Sower.Repo.put_org_id(socket.assigns.access_token.org_id)

    Logger.debug(msg: "Channel topic joined", topic: "agent:lobby", conn_sid: conn_sid)

    {:ok, %{conn_sid: conn_sid}, socket}
  end

  def join(
        "agent:" <> topic_sid = topic,
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

    case Orchestration.get_agent_sid(topic_sid) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      agent when is_nil(agent.local_sid) ->
        {:error, %{reason: "unauthorized"}}

      agent when agent.local_sid == local_sid ->
        send(self(), :track_presence)
        send(self(), :replay_unresolved_deployments)
        {:ok, %{conn_sid: conn_sid}, assign(socket, :agent, agent)}

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join(topic, params, socket) do
    Logger.warning(
      msg: "Unauthorized join",
      topic: topic,
      params: params,
      socket: socket
    )

    {:error, %{reason: "unauthorized"}}
  end

  @impl Phoenix.Channel
  def handle_in("ping", _, socket) do
    Logger.debug(msg: "Received ping, ponging")
    {:reply, {:ok, :pong}, socket}
  end

  def handle_in("pong", %{"ref" => _ref}, socket) do
    {:reply, :ok, socket}
  end

  def handle_in("agent:hello", payload, socket) do
    case payload
         |> SowerClient.AgentHello.cast!()
         |> Sower.Orchestration.get_agent(socket) do
      {:ok, agent} ->
        Logger.debug(msg: "Replying to hello", agent: agent)
        {:reply, {:ok, agent}, assign(socket, :agent_sid, agent.sid)}

      {:error, error} ->
        Logger.error(msg: "Error returning hello", error: error)
        {:reply, {:error, error}, socket}
    end
  end

  handle_schema(SowerClient.Seed, &Sower.Seed.get_by_request/1)

  handle_schema(SowerClient.Orchestration.Subscription, fn req, socket ->
    Sower.Orchestration.register_subscription(req, socket.assigns.agent.id)
  end)

  handle_schema(SowerClient.Orchestration.SubscriptionSync, fn req, socket ->
    case Sower.Orchestration.sync_subscriptions(req.subscriptions, socket.assigns.agent.id) do
      {:ok, subscriptions} ->
        {:ok, %{subscriptions: subscriptions}}

      {:error, error} ->
        {:error, error}
    end
  end)

  handle_schema(SowerClient.Orchestration.DeploymentRequest, fn req, socket ->
    case Orchestration.handle_deployment_request(
           req,
           socket.assigns.agent
         ) do
      {:ok, request_id, _task} ->
        {:ok, %{request_id: request_id}}

      {:error, error} ->
        Logger.error(msg: "Invalid deployment request", error: error)
        {:error, error}
    end
  end)

  handle_schema(
    SowerClient.Orchestration.DeploymentResult,
    &Sower.Orchestration.record_deployment/1
  )

  handle_schema(SowerClient.Orchestration.AgentSeedsReport, fn report, socket ->
    Orchestration.update_agent_seed_generations(report, socket.assigns.agent)
  end)

  handle_schema(SowerClient.Storage.DeploymentLogUploadRequest, fn req, socket ->
    Sower.Storage.presign_deployment_log_upload(socket.assigns.agent, req)
  end)

  @impl Phoenix.Channel
  def handle_info(:track_presence, %Phoenix.Socket{assigns: %{agent: agent}} = socket) do
    Logger.debug(msg: "Tracking agent presence", agent_sid: agent.sid)

    {:ok, _} =
      Presence.track(self(), "agent:presence", socket.assigns.agent.sid, %{
        online_at: DateTime.utc_now()
      })

    {:noreply, socket}
  end

  def handle_info(
        :replay_unresolved_deployments,
        %Phoenix.Socket{assigns: %{agent: agent}} = socket
      ) do
    {:ok, deployments} = Orchestration.replay_unresolved_deployments(agent)

    if deployments != [] do
      Logger.debug(
        msg: "Replayed unresolved deployments after agent join",
        agent_sid: agent.sid,
        deployment_count: length(deployments)
      )
    end

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
