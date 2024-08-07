defmodule SowerWeb.ClientLive.Index do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :clients, Sower.Client.list())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Client")
    |> assign(:client, Sower.client().get!(id))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Client")
    |> assign(:client, %Sower.Client{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Clients")
    |> assign(:client, nil)
  end

  @impl true
  def handle_info({SowerWeb.ClientLive.FormComponent, {:saved, client}}, socket) do
    {:noreply, stream_insert(socket, :clients, client)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    client = Sower.Client.get!(id)
    {:ok, _} = Sower.Client.delete(client)

    {:noreply, stream_delete(socket, :clients, client)}
  end
end
