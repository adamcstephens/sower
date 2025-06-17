defmodule SowerWeb.AgentChannel do
  use Phoenix.Channel

  alias Sower.Orchestration
  require Logger

  def join("agent:lobby", _message, %{assigns: %{conn_sid: conn_sid}} = socket) do
    # TODO move to access token checking
    Sower.Accounts.Organization.list()
    |> List.first()
    |> Map.get(:org_id)
    |> Sower.Repo.put_org_id()

    Logger.debug(msg: "Channel topic joined", topic: "agent:all", conn_sid: conn_sid)
    {:ok, %{conn_sid: conn_sid}, dbg(socket)}
  end

  def join("agent:" <> topic_sid = topic, %{"local_sid" => local_sid}, socket) do
    # TODO move to access token checking
    Sower.Accounts.Organization.list()
    |> List.first()
    |> Map.get(:org_id)
    |> Sower.Repo.put_org_id()

    Logger.debug(msg: "Channel topic joined", topic: topic, local_sid: local_sid)

    case Orchestration.get_agent_sid(topic_sid) do
      nil ->
        {:error, %{reason: "unauthorized"}}

      agent ->
        if is_nil(agent.remote_sid) do
          {:error, %{reason: "unauthorized"}}
        end

        case agent.remote_sid do
          ^local_sid ->
            {:ok, dbg(socket)}

          _ ->
            {:error, %{reason: "unauthorized"}}
        end
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

  def handle_in("ping", _, socket) do
    Logger.debug(msg: "Received ping, ponging")
    {:reply, {:ok, :pong}, dbg(socket)}
  end

  def handle_in("pong", %{"ref" => _ref}, socket) do
    {:reply, :ok, dbg(socket)}
  end

  def handle_in("agent:hello", payload, socket) do
    case payload
         |> SowerClient.AgentHello.new!()
         |> get_agent() do
      {:ok, agent} ->
        Logger.debug(msg: "Replying to hello", agent: agent)
        {:reply, {:ok, agent}, assign(socket, :agent_sid, agent.sid)}

      {:error, error} ->
        Logger.error(msg: "Error returning hello", error: error)
        {:reply, {:error, error}, socket}
    end
  end

  def handle_info(:ping, %Phoenix.Socket{assigns: %{sid: sid}} = socket) do
    ref = Sower.Schema.Sid.generate()
    Logger.debug(msg: "Sending ping", sid: sid, ref: ref)
    push(socket, "ping", %{ref: ref})
    {:noreply, socket}
  end

  def handle_info(:ping_all, socket) do
    ref = Sower.Schema.Sid.generate()
    Logger.debug(msg: "Sending ping", ref: ref)
    broadcast(socket, "agent:lobby", :ping)
    {:noreply, socket}
  end

  defp get_agent(%SowerClient.AgentHello{agent_sid: nil, name: name, local_sid: remote_sid}) do
    case Orchestration.get_agent_remote_sid(remote_sid) do
      nil ->
        Orchestration.create_agent(%{name: name, remote_sid: remote_sid})

      agent ->
        if is_nil(agent.remote_sid) do
          Orchestration.update_agent(agent, %{remote_sid: remote_sid})
        end

        {:ok, agent}
    end
  end

  defp get_agent(%SowerClient.AgentHello{agent_sid: agent_sid, name: name, local_sid: remote_sid}) do
    case Orchestration.get_agent_sid(agent_sid) do
      nil ->
        {:error, :agent_sid_not_found}

      agent ->
        if is_nil(agent.remote_sid) do
          Orchestration.update_agent(agent, %{remote_sid: remote_sid})
        end

        {:ok, agent}
    end
  end

  # def handle_in(
  #       "seed:submit",
  #       %{
  #         "name" => name,
  #         "seed_type" => seed_type,
  #         "out_path" => out_path
  #       } = _seed,
  #       socket
  #     ) do
  #   case Sower.Seed.submit(%{name: name, seed_type: seed_type, out_path: out_path}) do
  #     {:ok, %Sower.Seed{} = seed} ->
  #       {:reply, {:ok, %{seed_id: seed.id}}, socket}
  #
  #     {:error, _err} ->
  #       {:reply, {:error, "failed to submit"}, socket}
  #   end
  # end
end
