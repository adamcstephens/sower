defmodule SowerWeb.Forge.ConnectionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Forge

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, url, socket) do
    %{path: path} = URI.parse(url)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:connection, Forge.get_connection!(id))
     |> assign(:current_path, path)}
  end

  def handle_event("add_repository", _, socket) do
    {:ok, url} =
      Sower.Forge.Oauth.create_redirect_url(
        socket.assigns.connection,
        socket.assigns.current_path
      )
      |> dbg()

    {:noreply, redirect(socket, external: url)}
  end

  defp page_title(:show), do: "Show Connection"
  defp page_title(:edit), do: "Edit Connection"
end
