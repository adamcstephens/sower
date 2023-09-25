defmodule SowerWeb.HookLive.Index do
  use SowerWeb, :live_view

  alias Sower.SCM
  alias Sower.SCM.Hook

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :hooks, SCM.list_hooks())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Hook")
    |> assign(:hook, SCM.get_hook!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Hook")
    |> assign(:hook, %Hook{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Hooks")
    |> assign(:hook, nil)
  end

  @impl true
  def handle_info({SowerWeb.HookLive.FormComponent, {:saved, hook}}, socket) do
    {:noreply, stream_insert(socket, :hooks, hook)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    hook = SCM.get_hook!(id)
    {:ok, _} = SCM.delete_hook(hook)

    {:noreply, stream_delete(socket, :hooks, hook)}
  end
end
