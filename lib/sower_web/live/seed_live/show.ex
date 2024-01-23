defmodule SowerWeb.SeedLive.Show do
  use SowerWeb, :live_view

  alias Sower.Forge

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:seed, Sower.Seed.get_seed!(id))}
  end

  defp page_title(:show), do: "Show Seed"
  defp page_title(:edit), do: "Edit Seed"
end
