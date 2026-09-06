defmodule SowerWeb.GardenLive.Index.Column do
  use TypedStruct

  typedstruct do
    field :key, atom(), enforce: true
    field :label, String.t(), enforce: true
    field :sort_field, atom()
    field :default, boolean(), default: false
    field :lockable, boolean(), default: false
  end
end

defmodule SowerWeb.GardenLive.Index do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias Sower.Orchestration.Garden
  alias SowerWeb.GardenLive.Index.Column
  alias SowerWeb.Presence

  @columns [
    %Column{key: :name, label: "Name", sort_field: :name, default: true, lockable: true},
    %Column{key: :online, label: "Online", default: true},
    %Column{key: :deploy, label: "Deploy", sort_field: :deploy_result, default: true},
    %Column{key: :version, label: "Version", sort_field: :version}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:presence")
    end

    {:ok,
     socket
     |> assign(:garden_presence, Presence.list("garden:presence"))
     |> assign(:columns, @columns)}
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

  defp filter_value(%Flop.Meta{flop: %Flop{filters: filters}}, field) do
    case Enum.find(filters, &(&1.field == field)) do
      %Flop.Filter{value: value} -> value
      nil -> nil
    end
  end

  defp filter_value(_meta, _field), do: nil

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

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters =
      case params["name"] do
        nil -> []
        "" -> []
        name -> [%Flop.Filter{field: :name, op: :ilike_and, value: name}]
      end

    flop = %Flop{filters: filters}
    path = Flop.Phoenix.build_path(~p"/gardens", flop)

    {:noreply, push_patch(socket, to: path)}
  end
end
