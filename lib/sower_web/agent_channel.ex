defmodule SowerWeb.AgentChannel do
  use Phoenix.Channel

  alias Sower.Orchestration
  require Logger

  def join("agent:lobby", _message, %{assigns: %{conn_sid: conn_sid}} = socket) do
    Sower.Accounts.Organization.list()
    |> List.first()
    |> Map.get(:org_id)
    |> Sower.Repo.put_org_id()

    Logger.debug(msg: "Channel topic joined", topic: "agent:all", conn_sid: conn_sid)
    {:ok, %{conn_sid: conn_sid}, socket}
  end

  def join("agent:" <> topic_sid = topic, _params, %{assigns: %{sid: sid}} = socket) do
    Logger.debug(msg: "Channel topic joined", topic: topic, sid: sid)

    if sid == topic_sid do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("ping", _, %{assigns: %{sid: sid}} = socket) do
    Logger.debug(msg: "Received ping, ponging", sid: sid)
    {:reply, {:ok, :pong}, socket}
  end

  def handle_in("pong", %{"ref" => _ref}, %{assigns: %{sid: _sid}} = socket) do
    {:reply, :ok, socket}
  end

  def handle_in("agent:hello", payload, socket) do
    agent =
      payload
      |> SowerClient.AgentHello.new!()
      |> get_agent()
      |> dbg()

    {:reply, agent, socket}
  end

  def handle_info(:ping, %Phoenix.Socket{assigns: %{sid: sid}} = socket) do
    ref = Sower.Schema.Sid.generate()
    Logger.debug(msg: "Sending ping", sid: sid, ref: ref)
    push(socket, "ping", %{ref: ref})
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
