defmodule SowerWeb.Forge.ConnectionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Forge

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _url, socket) do
    forge = Forge.get_connection_sid!(sid) |> Sower.Repo.preload(:repositories)

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:connection, forge)
     |> assign(:logged_in, Forge.Oauth.logged_in?(forge, socket.assigns.current_user.id))
     |> assign_repositories()}
  end

  @impl true
  def handle_event("add_repo", client_api_repo, socket) do
    forge = socket.assigns.connection

    {:ok, %Oidcc.Token{access: %Oidcc.Token.Access{token: access_token}}} =
      Forge.Oauth.get_token(forge, socket.assigns.current_user.id)

    socket =
      case Sower.Forge.add_forge_repository(forge, client_api_repo, access_token) do
        {:ok, _} -> put_flash(socket, :info, "Added repository")
        {:error, _} -> put_flash(socket, :error, "Failed to add repository")
      end

    {:noreply, refresh_forge(socket)}
  end

  def handle_event("remove_repo", %{"repo_id" => repo_id}, socket) do
    forge = socket.assigns.connection
    repository = Forge.get_repository!(repo_id)

    {:ok, %Oidcc.Token{access: %Oidcc.Token.Access{token: access_token}}} =
      Forge.Oauth.get_token(forge, socket.assigns.current_user.id)

    socket =
      case Sower.Forge.remove_forge_repository(forge, repository, access_token) do
        {:ok, _} -> put_flash(socket, :info, "Removed repository")
        {:error, _} -> put_flash(socket, :error, "Failed to remove repository")
      end

    {:noreply, refresh_forge(socket)}
  end

  defp assign_repositories(socket) do
    repositories =
      if socket.assigns.logged_in do
        with {:ok, token} <-
               Forge.Oauth.get_token(socket.assigns.connection, socket.assigns.current_user.id),
             {:ok, repos} <-
               Forge.ClientApi.new(socket.assigns.connection, token.access.token)
               |> Forge.ClientApi.get_repos(socket.assigns.connection) do
          existing = Forge.list_forge_repositories_fullnames(socket.assigns.connection)

          repos
          |> Enum.filter(&(&1["full_name"] not in existing))
        else
          _ -> []
        end
      else
        []
      end

    socket |> assign(:repositories, repositories)
  end

  defp refresh_forge(socket) do
    forge =
      Sower.Forge.get_connection!(socket.assigns.connection.id)
      |> Sower.Repo.preload(:repositories)

    socket |> assign(:connection, forge) |> assign_repositories()
  end

  defp page_title(:show), do: "Show Connection"
  defp page_title(:edit), do: "Edit Connection"
end
