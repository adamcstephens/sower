defmodule SowerWeb.AgentChannel do
  import Sower.Authorization
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
         |> SowerClient.AgentHello.new!()
         |> get_agent(socket) do
      {:ok, agent} ->
        Logger.debug(msg: "Replying to hello", agent: agent)
        {:reply, {:ok, agent}, assign(socket, :agent_sid, agent.sid)}

      {:error, error} ->
        Logger.error(msg: "Error returning hello", error: error)
        {:reply, {:error, error}, socket}
    end
  end

  def handle_in("agent:current_generation", payload, socket) do
    payload = to_struct(Nix.Profile.Generation, payload)

    created = payload.created |> DateTime.from_iso8601() |> elem(1)

    store_path = Sower.Nix.submit_store_path!(payload.path)

    Sower.Distribution.create_deployment(%{deployed_at: created, store_paths: [store_path]})

    Phoenix.PubSub.broadcast(Sower.PubSub, "agent:view:#{socket.assigns.agent.sid}", payload)

    {:noreply, socket}
  end

  defp to_struct(new_struct, new_map) do
    new_map =
      for {key, val} <- new_map, into: %{} do
        {String.to_atom(key), val}
      end

    struct(new_struct, new_map)
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
    ref = Sower.Schema.Sid.generate()
    Logger.debug(msg: "Sending ping", ref: ref)
    push(socket, "ping", %{ref: ref})
    {:noreply, socket}
  end

  defp get_agent(
         %SowerClient.AgentHello{agent_sid: nil, name: name, local_sid: local_sid},
         socket
       ) do
    case Orchestration.get_agent_local_sid(local_sid) do
      nil ->
        Logger.debug(
          msg: "Registering new agent",
          name: name,
          local_sid: local_sid
        )

        if socket.assigns.access_token |> can() |> create?(Sower.Orchestration.Agent) do
          Orchestration.create_agent(%{name: name, local_sid: local_sid})
        else
          {:error, :unauthorized}
        end

      %Orchestration.Agent{} = agent ->
        Logger.error(
          msg: "Local agent attempted to re-register existing agent",
          name: agent.name,
          local_sid: local_sid,
          existing_agent_sid: agent.sid
        )

        {:error, :unauthorized_agent_hello}
    end
  end

  defp get_agent(
         %SowerClient.AgentHello{agent_sid: agent_sid, name: name, local_sid: local_sid},
         socket
       ) do
    case Orchestration.get_agent_sid(agent_sid) do
      nil ->
        Logger.debug(
          msg: "Local agent requested a missing agent",
          name: name,
          local_sid: local_sid,
          requested_agent_sid: agent_sid
        )

        if socket.assigns.access_token |> can() |> create?(Sower.Orchestration.Agent) do
          Orchestration.create_agent(%{name: name, local_sid: local_sid})
        else
          {:error, :unauthorized}
        end

      %Orchestration.Agent{local_sid: nil} = agent when agent.name == name ->
        Logger.debug(
          msg: "Registering local sid to existing agent",
          name: agent.name,
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        if socket.assigns.access_token |> can() |> create?(Sower.Orchestration.Agent) do
          Orchestration.update_agent(agent, %{local_sid: local_sid})

          {:ok, agent}
        else
          {:error, :unauthorized_agent_hello}
        end

      %Orchestration.Agent{} = agent
      when agent.sid == agent_sid and
             agent.name == name and
             agent.local_sid == local_sid ->
        Logger.debug(
          msg: "Found matching agent",
          name: agent.name,
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        {:ok, agent}

      %Orchestration.Agent{} = agent ->
        Logger.error(
          msg: "Invalid agent request",
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        {:error, :unauthorized_agent_hello}
    end
  end
end
