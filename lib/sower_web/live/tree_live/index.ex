defmodule SowerWeb.TreeLive.Index do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :trees, Sower.Tree.read_all!())}
  end
end
