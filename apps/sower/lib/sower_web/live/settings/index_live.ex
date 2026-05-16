defmodule SowerWeb.Settings.IndexLive do
  use SowerWeb, :live_view

  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      nav_section={assigns[:nav_section]}
      sidebar_state={assigns[:sidebar_state]}
    >
      <.header class="text-center">
        Account Settings
      </.header>

      <div class="space-y-12 divide-y">
        <.link navigate={~p"/settings/access-tokens"}>Access Tokens</.link>
      </div>
    </Layouts.app>
    """
  end

  def mount(%{"token" => _token}, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/settings")}
  end

  def mount(_params, _session, socket) do
    _user = socket.assigns.current_user

    {:ok, socket}
  end
end
