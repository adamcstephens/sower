defmodule SowerWeb.Forge.ConnectionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Forge

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    forge = Forge.get_connection!(id)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:connection, forge)
     |> assign(:logged_in, Forge.Oauth.logged_in?(forge, socket.assigns.current_user.id))
     |> assign_repositories(forge, socket.assigns.current_user.id)}
  end

  defp assign_repositories(conn, %Forge.Connection{} = forge, user_id) do
    repositories =
      if conn.assigns.logged_in do
        with {:ok, token} <- Forge.Oauth.get_token(forge, user_id),
             {:ok, repos} <-
               Forgejo.Client.new(forge.url, token.access.token)
               |> Forgejo.Client.get_user_repos() do
          repos
        else
          _ -> []
        end
      else
        []
      end

    conn |> assign(:repositories, repositories)
  end

  defp page_title(:show), do: "Show Connection"
  defp page_title(:edit), do: "Edit Connection"
end
