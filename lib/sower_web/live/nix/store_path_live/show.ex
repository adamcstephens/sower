defmodule SowerWeb.Nix.StorePathLive.Show do
  use SowerWeb, :live_view

  alias Sower.Nix

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"digest" => digest}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:store_path, Nix.get_store_path_digest!(digest) |> Sower.Repo.preload(:seeds))}
  end

  defp page_title(:show), do: "Show Store path"
end
