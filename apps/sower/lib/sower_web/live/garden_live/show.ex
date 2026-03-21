defmodule SowerWeb.GardenLive.Show do
  use SowerWeb, :live_view

  alias Phoenix.Socket.Broadcast
  alias Sower.Orchestration
  alias SowerWeb.Presence

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:presence")
    end

    {:ok, add_online_status(socket)}
  end

  @impl true
  def handle_params(%{"sid" => sid} = params, _, socket) do
    case Orchestration.get_garden_sid(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Garden not found")
         |> redirect(to: ~p"/gardens")}

      garden ->
        garden = Sower.Repo.preload(garden, :subscriptions)
        deployments = Orchestration.list_deployments(garden, limit: 10)

        generations_filter = Map.get(params, "generations_filter", "current")
        generations = load_generations(garden, generations_filter)

        deployable_subs = resolve_deployable_subscriptions(garden.subscriptions)

        socket =
          socket
          |> assign(:page_title, page_title(socket.assigns.live_action))
          |> assign(:garden, garden)
          |> assign(:deployments, deployments)
          |> add_online_status()
          |> assign(:current_generation, %{})
          |> assign(:generations_filter, generations_filter)
          |> assign(:generations, generations)
          |> assign(:deployable_subs, deployable_subs)
          |> assign(:deploying_sub, nil)
          |> assign(:deploy_error, nil)
          |> assign(:retrying_deployment, nil)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Sower.PubSub, "garden:view:#{sid}")
          Phoenix.PubSub.subscribe(Sower.PubSub, "deployments:garden:#{sid}")
        end

        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(%Broadcast{topic: "garden:presence", event: "presence_diff"}, socket) do
    {:noreply, add_online_status(socket)}
  end

  def handle_info({:deployment, :created, deployment}, socket) do
    if socket.assigns.deploying_sub do
      {:noreply,
       socket
       |> assign(:deploying_sub, nil)
       |> redirect(to: ~p"/deployments/#{deployment.sid}")}
    else
      deployments = Orchestration.list_deployments(socket.assigns.garden, limit: 10)
      {:noreply, assign(socket, :deployments, deployments)}
    end
  end

  def handle_info({:deployment, _event, _deployment}, socket) do
    deployments = Orchestration.list_deployments(socket.assigns.garden, limit: 10)
    {:noreply, assign(socket, :deployments, deployments)}
  end

  def handle_info({SowerWeb.GardenLive.FormComponent, {:saved, garden}}, socket) do
    garden = Sower.Repo.preload(garden, :subscriptions)
    {:noreply, assign(socket, :garden, garden)}
  end

  @impl true
  def handle_event("deploy_subscription", %{"subscription_sid" => sub_sid}, socket) do
    subscription = Enum.find(socket.assigns.garden.subscriptions, &(&1.sid == sub_sid))

    case subscription do
      nil ->
        {:noreply, assign(socket, :deploy_error, "Subscription not found")}

      sub ->
        socket = assign(socket, deploying_sub: sub_sid, deploy_error: nil)

        case Orchestration.deploy_subscription(sub, force: true) do
          {:ok, _request_id} ->
            {:noreply, socket}

          {:error, reason} ->
            {:noreply,
             assign(socket, deploying_sub: nil, deploy_error: deploy_error_message(reason))}
        end
    end
  end

  def handle_event("set_generations_filter", %{"filter" => filter}, socket) do
    generations = load_generations(socket.assigns.garden, filter)

    socket =
      socket
      |> assign(:generations_filter, filter)
      |> assign(:generations, generations)
      |> push_patch(to: ~p"/gardens/#{socket.assigns.garden}?generations_filter=#{filter}")

    {:noreply, socket}
  end

  def handle_event("retry_deployment", %{"deployment_sid" => deployment_sid}, socket) do
    socket = assign(socket, :retrying_deployment, deployment_sid)

    case Enum.find(socket.assigns.deployments, &(&1.sid == deployment_sid)) do
      nil ->
        {:noreply,
         socket
         |> assign(:retrying_deployment, nil)
         |> put_flash(:error, "Deployment not found")}

      deployment ->
        case Orchestration.retry_deployment(deployment, socket.assigns.current_user.id) do
          {:ok, _retry_deployment} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment, nil)
             |> put_flash(:info, "Retry deployment created")}

          {:error, :deployment_not_retryable} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment, nil)
             |> put_flash(:error, "Only successful or failed deployments can be retried")}

          {:error, :retry_in_progress} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment, nil)
             |> put_flash(:error, "A retry is already in progress for this deployment")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment, nil)
             |> put_flash(:error, "Failed to retry deployment")}
        end
    end
  end

  defp add_online_status(%{assigns: %{garden: garden}} = socket) do
    online_gardens = Presence.list("garden:presence") |> Map.keys()
    assign(socket, :online, garden.sid in online_gardens)
  end

  defp add_online_status(socket) do
    assign(socket, :online, false)
  end

  defp page_title(:show), do: "Show Garden"
  defp page_title(:edit), do: "Edit Garden"

  defp load_generations(garden, "all") do
    Sower.Orchestration.list_garden_seed_generation(garden)
  end

  defp load_generations(garden, "current") do
    Sower.Orchestration.list_current_seed_generation(garden)
  end

  defp load_generations(garden, _), do: load_generations(garden, "current")

  defp resolve_deployable_subscriptions(subscriptions) do
    subscriptions
    |> Enum.filter(fn sub -> Orchestration.match_seed(sub) != nil end)
    |> MapSet.new(& &1.sid)
  end

  defp deploy_error_message(:garden_not_found), do: "Garden not found"
  defp deploy_error_message(_), do: "Deployment failed"
end
