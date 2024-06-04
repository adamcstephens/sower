defmodule SowerWeb.TreeLive.Show do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:tree, Sower.Tree.by_id!(id))}
  end

  defp page_title(:show), do: "Show Tree"
end
