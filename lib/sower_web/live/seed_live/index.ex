defmodule SowerWeb.SeedLive.Index do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :seeds, Sower.Seed.list_seeds())}
  end

  @impl true
  def handle_event("create", %{"seed" => seed_params}, socket) do
    {:ok, seed} = Sower.Seed.create_seed(seed_params)

    {:noreply, stream_insert(socket, :seeds, seed)}
  end
end
