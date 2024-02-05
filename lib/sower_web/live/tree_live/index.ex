defmodule SowerWeb.TreeLive.Index do
  use SowerWeb, :live_view

  alias Sower.Plant
  alias Sower.Plant.Tree

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :trees, Plant.list_trees())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Tree")
    |> assign(:tree, Plant.get_tree!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Tree")
    |> assign(:tree, %Tree{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Trees")
    |> assign(:tree, nil)
  end

  @impl true
  def handle_info({SowerWeb.TreeLive.FormComponent, {:saved, tree}}, socket) do
    {:noreply, stream_insert(socket, :trees, tree)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    tree = Plant.get_tree!(id)
    {:ok, _} = Plant.delete_tree(tree)

    {:noreply, stream_delete(socket, :trees, tree)}
  end
end
