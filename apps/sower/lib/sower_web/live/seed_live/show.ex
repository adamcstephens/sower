defmodule SowerWeb.SeedLive.Show do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    dbg(socket)
    seed = Sower.Seed.get_sid!(sid) |> Sower.Repo.preload(:tags)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:seed, seed)}
  end

  defp page_title(:show), do: "Show Seed"
end
