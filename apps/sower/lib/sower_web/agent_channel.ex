defmodule SowerWeb.AgentChannel do
  use Phoenix.Channel

  alias Sower.Orchestration
  alias SowerWeb.Presence
  require Logger

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
         |> SowerClient.Schemas.AgentHello.cast!()
         |> Sower.Orchestration.get_agent(socket) do
      {:ok, agent} ->
        Logger.debug(msg: "Replying to hello", agent: agent)
        {:reply, {:ok, agent}, assign(socket, :agent_sid, agent.sid)}

      {:error, error} ->
        Logger.error(msg: "Error returning hello", error: error)
        {:reply, {:error, error}, socket}
    end
  end

  def handle_in("seed:get", payload, socket) do
    handle_message(payload, SowerClient.Schemas.Seed, socket, &Sower.Seed.get_by_request/1)
  end

  def handle_in("subscription:register", payload, socket) do
    handle_message(payload, SowerClient.Schemas.Orchestration.Subscription, socket, fn req ->
      Sower.Orchestration.register_subscription(req, socket.assigns.agent.id)
    end)
  end

  def handle_in("deployment:request", payload, socket) do
    handle_message(
      payload,
      SowerClient.Schemas.Orchestration.DeploymentRequest,
      socket,
      &Sower.Orchestration.request_deployment/1
    )
  end

  def handle_in("deployment:result", payload, socket) do
    handle_message(
      payload,
      SowerClient.Schemas.Orchestration.DeploymentResult,
      socket,
      &Sower.Orchestration.record_deployment/1
    )
  end

  @impl Phoenix.Channel
  def handle_info(:track_presence, %Phoenix.Socket{assigns: %{agent: agent}} = socket) do
    Logger.debug(msg: "Tracking agent presence", agent_sid: agent.sid)

    {:ok, _} =
      Presence.track(self(), "agent:presence", socket.assigns.agent.sid, %{
        online_at: DateTime.utc_now()
      })

    {:noreply, socket}
  end

  def handle_info(:ping, socket) do
    ref = SowerClient.Schemas.Sid.generate()
    Logger.debug(msg: "Sending ping", ref: ref, component: :server, topic: socket.topic)
    push(socket, "ping", %{ref: ref})
    {:noreply, socket}
  end

  # provide a standard way of casting the schemas and handling the errors
  defp handle_message(payload, schema, socket, fun) do
    with {:ok, params} <- schema.cast(payload),
         {:ok, result} <- fun.(params) do
      {:reply, {:ok, result}, socket}
    else
      nil ->
        {:reply, {:error, :not_found}, socket}

      {:error, _} = error ->
        Logger.error(msg: "Channel handler error", error: error, topic: socket.topic)
        {:reply, error, socket}
    end
  end
end
