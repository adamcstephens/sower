defmodule SowerWeb.GardenLive.Index do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias Sower.Orchestration.Garden
  alias SowerWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:presence")
    end

    {:ok,
     stream(socket, :gardens, Orchestration.list_gardens_with_latest_deployment())
     |> assign(:garden_presence, Presence.list("garden:presence"))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Garden")
    |> assign(:garden, %Garden{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Gardens")
    |> assign(:garden, nil)
  end

  @impl true
  def handle_info({SowerWeb.GardenLive.FormComponent, {:saved, garden}}, socket) do
    {:noreply, stream_insert(socket, :gardens, garden)}
  end

  @impl true
  def handle_info(%Broadcast{topic: "garden:presence", event: "presence_diff"}, socket) do
    # update the presence list, then touch the stream to force a table refresh
    socket =
      socket
      |> assign(:garden_presence, Presence.list("garden:presence"))
      |> stream(:gardens, Orchestration.list_gardens_with_latest_deployment())

    {:noreply, socket}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    garden = Orchestration.get_garden!(id)
    {:ok, _} = Orchestration.delete_garden(garden)

    {:noreply, stream_delete(socket, :gardens, garden)}
  end
end
