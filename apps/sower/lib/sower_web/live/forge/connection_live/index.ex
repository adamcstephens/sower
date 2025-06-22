defmodule SowerWeb.Forge.ConnectionLive.Index do
  use SowerWeb, :live_view

  alias Sower.Forge
  alias Sower.Forge.Connection

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :forges, Forge.list_forges())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"sid" => sid}) do
    socket
    |> assign(:page_title, "Edit Connection")
    |> assign(:connection, Forge.get_connection_sid!(sid))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Connection")
    |> assign(:connection, %Connection{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Forges")
    |> assign(:connection, nil)
  end

  @impl true
  def handle_info({SowerWeb.Forge.ConnectionLive.FormComponent, {:saved, connection}}, socket) do
    {:noreply, stream_insert(socket, :forges, connection)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    connection = Forge.get_connection!(id)
    {:ok, _} = Forge.delete_connection(connection)

    {:noreply, stream_delete(socket, :forges, connection)}
  end
end
