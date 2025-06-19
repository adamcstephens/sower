defmodule SowerWeb.AgentLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:agent, Orchestration.get_agent_sid!(sid))}
  end

  defp page_title(:show), do: "Show Agent"
  defp page_title(:edit), do: "Edit Agent"
end
