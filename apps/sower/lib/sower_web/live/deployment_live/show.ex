defmodule SowerWeb.DeploymentLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Deployment {@deployment.id}
        <:subtitle>This is a deployment record from your database.</:subtitle>
        <:actions>
          <.link patch={~p"/deployments"}>
            <.button>
              <.icon name="hero-arrow-left" />
            </.button>
          </.link>
        </:actions>
      </.header>

      <.list>
        <:item title="sid">{@deployment.sid}</:item>
        <:item title="Subscriptions">
          <.table
            id="subscriptions"
            rows={@deployment.subscriptions}
            row_click={fn subscription -> JS.navigate(~p"/subscriptions/#{subscription.sid}") end}
          >
            <:col :let={subscription} label="agent">{subscription.agent.name}</:col>
            <:col :let={subscription} label="info">
              {subscription.seed_type}/{subscription.seed_name}
            </:col>
          </.table>
        </:item>
        <:item title="Seeds">
          <.table
            id="seeds"
            rows={@deployment.seeds}
            row_click={fn seed -> JS.navigate(~p"/seeds/#{seed.sid}") end}
          >
            <:col :let={seed}>
              {seed.seed_type}/{seed.name}
            </:col>
            <:col :let={seed}>
              {seed.artifact}
            </:col>
          </.table>
        </:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"sid" => sid}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Deployment")
     |> assign(
       :deployment,
       Orchestration.get_deployment_sid!(sid)
       |> Sower.Repo.preload([:seeds, subscriptions: [:agent]])
     )}
  end
end
