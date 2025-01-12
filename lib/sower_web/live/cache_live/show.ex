defmodule SowerWeb.CacheLive.Show do
  use SowerWeb, :live_view

  alias Sower.Nix

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:cache, Nix.get_cache!(id))}
  end

  defp page_title(:show), do: "Show Cache"
  defp page_title(:edit), do: "Edit Cache"
end
