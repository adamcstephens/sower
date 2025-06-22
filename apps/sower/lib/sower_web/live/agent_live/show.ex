defmodule SowerWeb.AgentLive.Show do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias SowerWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "agent:presence")
    end

    {:ok, add_online_status(socket)}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    socket =
      socket
      |> assign(:page_title, page_title(socket.assigns.live_action))
      |> assign(:agent, Orchestration.get_agent_sid!(sid))
      |> add_online_status()

    {:noreply, socket}
  end

  @impl true
  def handle_info(%Broadcast{topic: "agent:presence", event: "presence_diff"}, socket) do
    {:noreply, add_online_status(socket)}
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
