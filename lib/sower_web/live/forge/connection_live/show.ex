defmodule SowerWeb.Forge.ConnectionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Forge

  @impl true
  def mount(_params, session, socket) do
    {:ok, socket |> assign(:oauth_code, session["oauth_code"])}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    forge = Forge.get_connection!(id)
    Sower.Forge.Oauth.retrieve_token(forge, socket.assigns.oauth_code |> dbg()) |> dbg()

    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:connection, forge)}
  end

  defp page_title(:show), do: "Show Connection"
  defp page_title(:edit), do: "Edit Connection"
end
