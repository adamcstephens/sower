defmodule SowerWeb.SeedLive.Index do
  use SowerWeb, :live_view

  alias Sower.Orchestration.Seed

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    case Seed.list_flop(params) do
      {:ok, {seeds, meta}} ->
        {:noreply, assign(socket, seeds: seeds, meta: meta)}

      {:error, meta} ->
        {:noreply, assign(socket, seeds: [], meta: meta)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("filter", params, socket) do
    filters =
      []
      |> maybe_add_filter(:name, :ilike_and, params["name"])
      |> maybe_add_filter(:seed_type, :==, params["seed_type"])

    flop = %Flop{filters: filters}
    path = Flop.Phoenix.build_path(~p"/seeds", flop)

    {:noreply, push_patch(socket, to: path)}
  end

  defp maybe_add_filter(filters, _field, _op, nil), do: filters
  defp maybe_add_filter(filters, _field, _op, ""), do: filters

  defp maybe_add_filter(filters, field, op, value) do
    filters ++ [%Flop.Filter{field: field, op: op, value: value}]
  end

  defp filter_value(%Flop.Meta{flop: %Flop{filters: filters}}, field) do
    case Enum.find(filters, &(&1.field == field)) do
      %Flop.Filter{value: value} -> value
      nil -> nil
    end
  end

  defp filter_value(_meta, _field), do: nil

  defp seed_types, do: SowerClient.Seed.seed_types()
end
