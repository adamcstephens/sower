defmodule SowerWeb.SeedLive.Index do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :seeds, Sower.Seed.read_all!())}
  end
end
