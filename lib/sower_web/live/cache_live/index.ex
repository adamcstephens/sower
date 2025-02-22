defmodule SowerWeb.CacheLive.Index do
  use SowerWeb, :live_view

  alias Sower.Nix
  alias Sower.Nix.Cache

  @impl true
  def mount(_params, _session, socket) do
    {:ok, stream(socket, :nix_caches, Nix.list_nix_caches())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"sid" => sid}) do
    socket
    |> assign(:page_title, "Edit Cache")
    |> assign(:cache, Nix.get_cache_sid!(sid))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Cache")
    |> assign(:cache, %Cache{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Nix caches")
    |> assign(:cache, nil)
  end

  @impl true
  def handle_info({SowerWeb.CacheLive.FormComponent, {:saved, cache}}, socket) do
    {:noreply, stream_insert(socket, :nix_caches, cache)}
  end

  @impl true
  def handle_event("delete", %{"sid" => sid}, socket) do
    cache = Nix.get_cache_sid!(sid)
    {:ok, _} = Nix.delete_cache(cache)

    {:noreply, stream_delete(socket, :nix_caches, cache)}
  end
end
