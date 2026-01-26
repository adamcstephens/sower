defmodule SowerWeb.SubscriptionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  import SowerWeb.SowerComponents

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_sid" => agent_sid, "sid" => sid}, _, socket) do
    agent = Orchestration.get_agent_sid!(agent_sid)

    case Orchestration.get_subscription_sid_with_deployments(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Subscription not found")
         |> redirect(to: ~p"/agents/#{agent}/subscriptions")}

      subscription ->
        matching_seeds = Orchestration.list_matching_seeds(subscription, 5)

        # TODO find the generations in the current visible seed list
        # matching_generations = matching_seeds |> Enum.map(

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Sower.PubSub, "deployments:subscription:#{sid}")
        end

        {:noreply,
         socket
         |> assign(:agent, agent)
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:subscription, subscription)
         |> assign(:matching_seeds, matching_seeds)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, _event, _deployment}, socket) do
    subscription =
      Orchestration.get_subscription_sid_with_deployments!(socket.assigns.subscription.sid)

    matching_seeds = Orchestration.list_matching_seeds(subscription, 5)

    {:noreply,
     socket
     |> assign(:subscription, subscription)
     |> assign(:matching_seeds, matching_seeds)}
  end

  defp page_title(:show), do: "Show Subscription"
  defp page_title(:edit), do: "Edit Subscription"
end
