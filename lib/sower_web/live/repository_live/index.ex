defmodule SowerWeb.RepositoryLive.Index do
  use SowerWeb, :live_view

  alias Sower.Forge
  alias Sower.Forge.Repository

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :repositories, Forge.list_repositories())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Repository")
    |> assign(:repository, Forge.get_repository!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Repository")
    |> assign(:repository, %Repository{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Repositories")
    |> assign(:repository, nil)
  end

  @impl true
  def handle_info({SowerWeb.RepositoryLive.FormComponent, {:saved, repository}}, socket) do
    {:noreply, stream_insert(socket, :repositories, repository)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    repository = Forge.get_repository!(id)
    {:ok, _} = Forge.delete_repository(repository)

    {:noreply, stream_delete(socket, :repositories, repository)}
  end
end
