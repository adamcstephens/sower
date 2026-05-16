defmodule SowerWeb.SidebarState do
  @moduledoc """
  Tracks the user's sidebar expand/collapse preference.

  The state is persisted in a `sidebar` cookie written client-side by a small
  JS hook that listens for the `sower:set-cookie` event. The plug reads the
  cookie on each browser request into `conn.assigns[:sidebar_state]` and the
  session, so the LiveView `on_mount` callback can pick it up for SSR-correct
  first paint. The `attach_hook/4` for `:handle_event` listens for
  `toggle_sidebar`, flips the assign, and emits the cookie-set event back to
  the client.
  """

  alias Phoenix.Component
  alias Phoenix.LiveView

  @cookie "sidebar"
  @default :expanded
  @states [:expanded, :rail]

  def init(opts), do: opts

  def call(conn, _opts) do
    state = state_from_cookie(conn.cookies[@cookie])

    conn
    |> Plug.Conn.assign(:sidebar_state, state)
    |> Plug.Conn.put_session(:sidebar_state, state)
  end

  def on_mount(:default, _params, session, socket) do
    state = state_from_session(session)

    socket =
      socket
      |> Component.assign(:sidebar_state, state)
      |> attach_toggle_hook()

    {:cont, socket}
  end

  defp attach_toggle_hook(socket) do
    LiveView.attach_hook(socket, :sidebar_toggle, :handle_event, &handle_toggle/3)
  end

  defp handle_toggle("toggle_sidebar", _params, socket) do
    next = toggle(socket.assigns.sidebar_state)

    socket =
      socket
      |> Component.assign(:sidebar_state, next)
      |> LiveView.push_event("sower:set-cookie", %{key: @cookie, value: to_string(next)})

    {:halt, socket}
  end

  defp handle_toggle(_event, _params, socket), do: {:cont, socket}

  defp toggle(:expanded), do: :rail
  defp toggle(_), do: :expanded

  defp state_from_session(session) do
    session
    |> Map.get("sidebar_state")
    |> normalize()
  end

  defp state_from_cookie("rail"), do: :rail
  defp state_from_cookie("expanded"), do: :expanded
  defp state_from_cookie(_), do: @default

  defp normalize(state) when state in @states, do: state
  defp normalize("rail"), do: :rail
  defp normalize("expanded"), do: :expanded
  defp normalize(_), do: @default
end
