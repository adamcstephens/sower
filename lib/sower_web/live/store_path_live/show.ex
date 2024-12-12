defmodule SowerWeb.StorePathLive.Show do
  use SowerWeb, :live_view

  alias Sower.StorePath

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:store_path, StorePath.get!(id))}
  end

  defp page_title(:show), do: "Show Store path"
end
