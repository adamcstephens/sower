defmodule SowerWeb.SubscriptionLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"garden_sid" => garden_sid, "sid" => sid} = params, _, socket) do
    garden = Orchestration.get_garden_sid!(garden_sid)

    case Orchestration.get_subscription_sid(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Subscription not found")
         |> redirect(to: ~p"/gardens/#{garden}/subscriptions")}

      subscription ->
        subscription = Sower.Repo.preload(subscription, :garden)
        flop_params = Map.take(params, ["page", "page_size", "order_by", "order_directions"])

        {seeds, meta} = load_seeds(subscription, garden, flop_params)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Sower.PubSub, "deployments:subscription:#{sid}")
        end

        {:noreply,
         socket
         |> assign(:garden, garden)
         |> assign(:page_title, page_title(socket.assigns.live_action))
         |> assign(:subscription, subscription)
         |> assign(:seeds, seeds)
         |> assign(:meta, meta)
         |> assign(:flop_params, flop_params)
         |> assign(:deployable, seeds != [])
         |> assign(:deploying, false)
         |> assign(:deploy_error, nil)}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("deploy_subscription", %{"subscription_sid" => _sub_sid}, socket) do
    socket = assign(socket, deploying: true, deploy_error: nil)

    user = socket.assigns.current_user

    case Orchestration.deploy_subscription(socket.assigns.subscription,
           force: true,
           actor_sid: user.sid,
           event_reason: :user_triggered
         ) do
      {:ok, _request_id, _pid} ->
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
      {:noreply, refresh_seeds(socket)}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, _event, _deployment}, socket) do
    {:noreply, refresh_seeds(socket)}
  end

  defp load_seeds(%Orchestration.Subscription{} = subscription, garden, flop_params) do
    case Orchestration.list_matching_seeds_enriched(subscription, garden.id, flop_params) do
      {:ok, {seeds, meta}} -> {seeds, meta}
      {:error, meta} -> {[], meta}
    end
  end

  defp refresh_seeds(socket) do
    {seeds, meta} =
      load_seeds(
        socket.assigns.subscription,
        socket.assigns.garden,
        socket.assigns.flop_params
      )

    socket
    |> assign(:seeds, seeds)
    |> assign(:meta, meta)
    |> assign(:deployable, seeds != [])
  end

  defp page_title(:show), do: "Show Subscription"
  defp page_title(:edit), do: "Edit Subscription"

  defp deploy_error_message(:garden_not_found), do: "Garden not found"
  defp deploy_error_message(_), do: "Deployment failed"
end
