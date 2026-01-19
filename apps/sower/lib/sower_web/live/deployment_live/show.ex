defmodule SowerWeb.DeploymentLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  import SowerWeb.SowerComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        <div class="flex items-center space-x-2">
          <.result result={@deployment.result} />
          <span>Deployment {@deployment.sid}</span>
        </div>
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
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Show Deployment")}
  end

  @impl true
  def handle_params(%{"sid" => sid}, _, socket) do
    case Orchestration.get_deployment_sid(sid) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Deployment not found")
         |> redirect(to: ~p"/deployments")}

      deployment ->
        deployment = Sower.Repo.preload(deployment, [:seeds, subscriptions: [:agent]])

        {:noreply, assign(socket, :deployment, deployment)}
    end
  end
end
