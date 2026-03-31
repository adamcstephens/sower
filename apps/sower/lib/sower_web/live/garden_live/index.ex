defmodule SowerWeb.GardenLive.Index do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias Sower.Orchestration.Garden
  alias SowerWeb.Presence

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:presence")
    end

    {:ok, assign(socket, :garden_presence, Presence.list("garden:presence"))}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _url, socket) do
    socket =
      case Orchestration.list_gardens_flop(params) do
        {:ok, {gardens, meta}} ->
          assign(socket, gardens: gardens, meta: meta)

        {:error, meta} ->
          assign(socket, gardens: [], meta: meta)
      end

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

  @impl Phoenix.LiveView
  def handle_info({SowerWeb.GardenLive.FormComponent, {:saved, _garden}}, socket) do
    case Orchestration.list_gardens_flop(socket.assigns.meta.flop) do
      {:ok, {gardens, meta}} ->
        {:noreply, assign(socket, gardens: gardens, meta: meta)}

      {:error, meta} ->
        {:noreply, assign(socket, gardens: [], meta: meta)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(%Broadcast{topic: "garden:presence", event: "presence_diff"}, socket) do
    socket =
      case Orchestration.list_gardens_flop(socket.assigns.meta.flop) do
        {:ok, {gardens, meta}} ->
          assign(socket,
            gardens: gardens,
            meta: meta,
            garden_presence: Presence.list("garden:presence")
          )

        {:error, meta} ->
          assign(socket,
            gardens: [],
            meta: meta,
            garden_presence: Presence.list("garden:presence")
          )
      end

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("delete", %{"id" => id}, socket) do
    garden = Orchestration.get_garden!(id)
    {:ok, _} = Orchestration.delete_garden(garden)

    case Orchestration.list_gardens_flop(socket.assigns.meta.flop) do
      {:ok, {gardens, meta}} ->
        {:noreply, assign(socket, gardens: gardens, meta: meta)}

      {:error, meta} ->
        {:noreply, assign(socket, gardens: [], meta: meta)}
    end
  end
end
