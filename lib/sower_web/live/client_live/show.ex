defmodule SowerWeb.ClientLive.Show do
  use SowerWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:client, Sower.Client.get_sid!(sid))}
  end

  defp page_title(:show), do: "Show Client"
  defp page_title(:edit), do: "Edit Client"
end
