defmodule SowerWeb.GardenLive.Index.Column do
  use TypedStruct

  typedstruct do
    field :key, atom(), enforce: true
    field :label, String.t(), enforce: true
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
    %Column{key: :name, label: "Name", default: true, lockable: true},
    %Column{key: :online, label: "Online", default: true},
    %Column{key: :deploy, label: "Deploy", default: true},
    %Column{key: :version, label: "Version"}
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
    visible_cols = parse_cols(params)

    socket =
      socket
      |> assign(:visible_cols, visible_cols)
      |> assign(:cols_path, cols_path(visible_cols))

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

  def handle_event("toggle_col", %{"col" => col}, socket) do
    new_cols = toggle_col(socket.assigns.visible_cols, col)
    path = Flop.Phoenix.build_path(cols_path(new_cols), socket.assigns.meta.flop)
    {:noreply, push_patch(socket, to: path)}
  end

  defp toggle_col(visible_cols, col) do
    case Enum.find(@columns, &(Atom.to_string(&1.key) == col)) do
      nil -> visible_cols
      %Column{lockable: true} -> visible_cols
      %Column{key: key} -> flip(visible_cols, key)
    end
  end

  defp flip(set, key) do
    if MapSet.member?(set, key),
      do: MapSet.delete(set, key),
      else: MapSet.put(set, key)
  end

  @doc false
  def parse_cols(params) do
    case Map.get(params, "cols") do
      raw when is_binary(raw) and raw != "" ->
        parsed =
          raw
          |> String.split(",", trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.flat_map(fn s ->
            case Enum.find(@columns, &(Atom.to_string(&1.key) == s)) do
              nil -> []
              %Column{key: key} -> [key]
            end
          end)
          |> MapSet.new()

        if MapSet.size(parsed) == 0 do
          default_cols()
        else
          MapSet.union(parsed, lockable_cols())
        end

      _ ->
        default_cols()
    end
  end

  @doc false
  def cols_query_string(visible_cols) do
    if MapSet.equal?(visible_cols, default_cols()) do
      ""
    else
      keys =
        @columns
        |> Enum.filter(&MapSet.member?(visible_cols, &1.key))
        |> Enum.map_join(",", &Atom.to_string(&1.key))

      "?cols=" <> keys
    end
  end

  defp cols_path(visible_cols), do: "/gardens" <> cols_query_string(visible_cols)

  defp default_cols, do: MapSet.new(for c <- @columns, c.default, do: c.key)
  defp lockable_cols, do: MapSet.new(for c <- @columns, c.lockable, do: c.key)
end
