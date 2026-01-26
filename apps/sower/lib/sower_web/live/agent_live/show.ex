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
    case Orchestration.get_agent_sid(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Agent not found")
         |> redirect(to: ~p"/agents")}

      agent ->
        agent = Sower.Repo.preload(agent, :subscriptions)
        deployments = Orchestration.list_deployments(agent, limit: 10)

        generations_filter = Map.get(params, "generations_filter", "current")
        generations = load_generations(agent, generations_filter)

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
  end

  @impl Phoenix.LiveView
  def handle_info(%Broadcast{topic: "agent:presence", event: "presence_diff"}, socket) do
    {:noreply, add_online_status(socket)}
  end

  def handle_info({:deployment, _event, _deployment}, socket) do
    deployments = Orchestration.list_deployments(socket.assigns.agent, limit: 10)
    {:noreply, assign(socket, :deployments, deployments)}
  end

  @impl true
  def handle_event("set_generations_filter", %{"filter" => filter}, socket) do
    generations = load_generations(socket.assigns.agent, filter)

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

  defp load_generations(agent, "all") do
    Sower.Orchestration.list_agent_seed_generation(agent)
  end

  defp load_generations(agent, "current") do
    Sower.Orchestration.list_current_seed_generation(agent)
  end

  defp load_generations(agent_id, _), do: load_generations(agent_id, "current")
end
