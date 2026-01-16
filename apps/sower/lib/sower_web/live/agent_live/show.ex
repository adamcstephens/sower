defmodule SowerWeb.AgentLive.Show do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias SowerWeb.Presence
  import SowerWeb.SowerComponents

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "agent:presence")
    end

    {:ok, add_online_status(socket)}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    agent =
      Orchestration.get_agent_sid!(sid)
      |> Sower.Repo.preload(:subscriptions)

    deployments = Orchestration.list_deployments_for_agent(agent, limit: 10)

    socket =
      socket
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign(:agent, agent)
      |> assign(:deployments, deployments)
      |> add_online_status()
      |> assign(:current_generation, %{})

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "agent:view:#{sid}")
    end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info(%Broadcast{topic: "agent:presence", event: "presence_diff"}, socket) do
    {:noreply, add_online_status(socket)}
  end

  def handle_info(
        %Nix.Profile.Generation{} = generation,
        socket
      ) do
    {:noreply, assign(socket, :current_generation, generation)}
  end

  defp add_online_status(%{assigns: %{agent: agent}} = socket) do
    online_agents = Presence.list("agent:presence") |> Map.keys()
    assign(socket, :online, agent.sid in online_agents)
  end

  defp add_online_status(socket) do
    assign(socket, :online, false)
  end

  defp page_title(:show), do: "Show Agent"
  defp page_title(:edit), do: "Edit Agent"
end
