defmodule SowerWeb.SubscriptionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    {:noreply,
     socket
     |> assign(:page_title, page_title(socket.assigns.live_action))
     |> assign(:subscription, Orchestration.get_subscription_sid!(sid))}
  end

  defp page_title(:show), do: "Show Subscription"
  defp page_title(:edit), do: "Edit Subscription"
end
