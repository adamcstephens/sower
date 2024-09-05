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

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Clients")
    |> assign(:client, nil)
  end
end
