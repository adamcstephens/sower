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
  def handle_params(%{"sid" => sid} = params, _, socket) do
    agent =
      Orchestration.get_agent_sid!(sid)
      |> Sower.Repo.preload(:subscriptions)

    deployments = Orchestration.list_deployments_for_agent(agent, limit: 10)

    generations_filter = Map.get(params, "generations_filter", "current")
    generations = load_generations(agent.id, generations_filter)

    socket =
      socket
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign(:agent, agent)
      |> assign(:deployments, deployments)
      |> add_online_status()
      |> assign(:current_generation, %{})
      |> assign(:generations_filter, generations_filter)
      |> assign(:generations, generations)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "agent:view:#{sid}")
      Phoenix.PubSub.subscribe(Sower.PubSub, "deployments:agent:#{sid}")
    end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info(%Broadcast{topic: "agent:presence", event: "presence_diff"}, socket) do
    {:noreply, add_online_status(socket)}
  end

  def handle_info(%Nix.Profile.Generation{} = generation, socket) do
    {:noreply, assign(socket, :current_generation, generation)}
  end

  def handle_info({:deployment, _event, _deployment}, socket) do
    deployments = Orchestration.list_deployments_for_agent(socket.assigns.agent, limit: 10)
    {:noreply, assign(socket, :deployments, deployments)}
  end

  @impl true
  def handle_event("set_generations_filter", %{"filter" => filter}, socket) do
    agent_id = socket.assigns.agent.id
    generations = load_generations(agent_id, filter)

    socket =
      socket
      |> assign(:generations_filter, filter)
      |> assign(:generations, generations)
      |> push_patch(to: ~p"/agents/#{socket.assigns.agent}?generations_filter=#{filter}")

    {:noreply, socket}
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

  defp load_generations(agent_id, "all") do
    Sower.Orchestration.AgentSeedGeneration.list_for_agent(agent_id)
  end

  defp load_generations(agent_id, "current") do
    Sower.Orchestration.AgentSeedGeneration.list_current_for_agent(agent_id)
  end

  defp load_generations(agent_id, _), do: load_generations(agent_id, "current")
end
