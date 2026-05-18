defmodule SowerWeb.SeedLive.Show do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    case Sower.Orchestration.Seed.get_sid(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Seed not found")
         |> redirect(to: ~p"/seeds")}

      seed ->
        seed = Sower.Repo.preload(seed, :tags)

        {:noreply,
         socket
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:seed, seed)
         |> assign(:crumbs, [{"Seeds", ~p"/seeds"}, {seed.name, nil}])}
    end
  end

  defp page_title(:show), do: "Show Seed"
end
