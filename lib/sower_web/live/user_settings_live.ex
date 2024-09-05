defmodule SowerWeb.UserSettingsLive do
  use SowerWeb, :live_view

  def render(assigns) do
    ~H"""
    <.header class="text-center">
      Account Settings
    </.header>

    <div class="space-y-12 divide-y"></div>
    """
  end

  def mount(%{"token" => _token}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    _user = socket.assigns.current_user

    {:ok, socket}
  end
end
