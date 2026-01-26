defmodule SowerWeb.SubscriptionLive.Index do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  alias Sower.Orchestration.Subscription

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_sid" => agent_sid} = params, _url, socket) do
    agent = Orchestration.get_agent_sid!(agent_sid)

    socket =
      socket
      |> assign(:agent, agent)
      |> stream(:subscriptions, Orchestration.list_subscriptions_for_agent(agent))

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"sid" => sid}) do
    socket
    |> assign(:page_title, "Edit Subscription")
    |> assign(:subscription, Orchestration.get_subscription_sid!(sid))
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Subscription")
    |> assign(:subscription, %Subscription{agent_id: socket.assigns.agent.id})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Listing Subscriptions")
    |> assign(:subscription, nil)
  end

  @impl true
  def handle_info({SowerWeb.SubscriptionLive.FormComponent, {:saved, subscription}}, socket) do
    {:noreply, stream_insert(socket, :subscriptions, subscription)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    subscription = Orchestration.get_subscription!(id)
    {:ok, _} = Orchestration.delete_subscription(subscription)

    {:noreply, stream_delete(socket, :subscriptions, subscription)}
  end
end
