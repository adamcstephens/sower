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
         |> assign(:matching_seeds, matching_seeds)
         |> assign(:deployable, matching_seeds != [])
         |> assign(:deploying, false)
         |> assign(:deploy_error, nil)}
    end
  end

  @impl true
  def handle_event("deploy_subscription", %{"subscription_sid" => _sub_sid}, socket) do
    socket = assign(socket, deploying: true, deploy_error: nil)

    case Orchestration.deploy_subscription(socket.assigns.subscription, force: true) do
      {:ok, _request_id} ->
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, deploying: false, deploy_error: deploy_error_message(reason))}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, :created, deployment}, socket) do
    if socket.assigns.deploying do
      {:noreply,
       socket
       |> assign(:deploying, false)
       |> redirect(to: ~p"/deployments/#{deployment.sid}")}
    else
      subscription =
        Orchestration.get_subscription_sid_with_deployments!(socket.assigns.subscription.sid)

      matching_seeds = Orchestration.list_matching_seeds(subscription, 5)

      {:noreply,
       socket
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

  defp deploy_error_message(:agent_not_found), do: "Agent not found"
  defp deploy_error_message(_), do: "Deployment failed"
end
