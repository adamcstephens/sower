defmodule SowerWeb.TreeLive.Show do
  use SowerWeb, :live_view

  alias Sower.Plant

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:tree, Plant.get_tree!(id))}
  end

  defp page_title(:show), do: "Show Tree"
  defp page_title(:edit), do: "Edit Tree"
end
