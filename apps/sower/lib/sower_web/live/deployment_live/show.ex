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
          <span>{@deployment.sid}</span>
        </div>
        <:actions>
          <.link patch={~p"/deployments"}>
            <.button>
              <.icon name="hero-arrow-left" />
            </.button>
          </.link>
        </:actions>
      </.header>

      <div class="mt-8 space-y-10">
        <.detail_field label="Completed">
          <.local_datetime datetime={@deployment.deployed_at} user_timezone={@user_timezone} />
        </.detail_field>

        <.detail_field label="Agent">
          <.link
            navigate={~p"/agents/#{@deployment.agent}"}
            class="hover:text-orange-500 dark:hover:text-orange-400"
          >
            {@deployment.agent.name}
          </.link>
        </.detail_field>

        <section>
          <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 mb-4">Subscriptions</h2>
          <.responsive_table
            id="subscriptions"
            rows={@deployment.subscriptions}
            row_click={
              fn subscription ->
                JS.navigate(~p"/agents/#{@deployment.agent}/subscriptions/#{subscription.sid}")
              end
            }
          >
            <:col :let={subscription} label="Subscription">
              {subscription.seed_type}/{subscription.seed_name}
            </:col>
          </.responsive_table>
          <p
            :if={@deployment.subscriptions == []}
            class="text-sm text-zinc-500 dark:text-zinc-400 italic"
          >
            No subscriptions.
          </p>
        </section>

        <section>
          <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 mb-4">Seeds</h2>
          <.responsive_table
            id="seeds"
            rows={@deployment.seeds}
            row_click={fn seed -> JS.navigate(~p"/seeds/#{seed.sid}") end}
          >
            <:col :let={seed} label="Seed">
              {seed.seed_type}/{seed.name}
            </:col>
            <:col :let={seed} label="Artifact">{seed.artifact}</:col>
          </.responsive_table>
          <p
            :if={@deployment.seeds == []}
            class="text-sm text-zinc-500 dark:text-zinc-400 italic"
          >
            No seeds.
          </p>
        </section>
      </div>
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
        deployment = Sower.Repo.preload(deployment, [:seeds, :subscriptions, :agent])

        {:noreply, assign(socket, :deployment, deployment)}
    end
  end
end
