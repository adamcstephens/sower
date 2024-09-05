defmodule SowerWeb.RepositoryLive.Index do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :repos, Sower.Inputs.Repository.list())}
  end
end
