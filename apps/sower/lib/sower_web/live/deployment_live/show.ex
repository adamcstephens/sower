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
          <div :if={@deployment.seeds != []} class="space-y-4">
            <article
              :for={seed <- @deployment.seeds}
              id={"seed-log-#{seed.sid}"}
              class="rounded-lg border border-zinc-200/50 dark:border-zinc-700/50 p-4"
            >
              <div class="flex items-center justify-between gap-4">
                <div class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 flex flex-wrap items-center gap-2">
                  <.link
                    navigate={~p"/seeds/#{seed.sid}"}
                    class="hover:text-orange-500 dark:hover:text-orange-400"
                  >
                    {seed.seed_type}/{seed.name}
                  </.link>
                  <span class="text-xs font-normal text-zinc-500 dark:text-zinc-400">
                    {seed.artifact}
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <.link
                    :if={expanded_seed_log?(@expanded_seed_logs, seed.sid)}
                    href={seed_log_url(@deployment.sid, seed.sid)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="text-sm text-orange-600 hover:text-orange-500 dark:text-orange-400 dark:hover:text-orange-300"
                  >
                    Open in new tab
                  </.link>
                  <button
                    type="button"
                    phx-click="toggle_seed_log"
                    phx-value-seed_sid={seed.sid}
                    class="rounded-md border border-zinc-300 dark:border-zinc-600 px-3 py-1.5 text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
                  >
                    {if expanded_seed_log?(@expanded_seed_logs, seed.sid),
                      do: "Hide log",
                      else: "View log"}
                  </button>
                </div>
              </div>
              <div
                :if={loaded_seed_log?(@loaded_seed_logs, seed.sid)}
                id={"seed-log-frame-#{seed.sid}"}
                class={["mt-3", !expanded_seed_log?(@expanded_seed_logs, seed.sid) && "hidden"]}
              >
                <iframe
                  src={seed_log_url(@deployment.sid, seed.sid)}
                  class="w-full h-80 rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-300 dark:invert"
                  title={"Seed deployment log #{seed.sid}"}
                />
              </div>
            </article>
          </div>
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
    {:ok,
     socket
     |> assign(:page_title, "Show Deployment")
     |> assign(:expanded_seed_logs, MapSet.new())
     |> assign(:loaded_seed_logs, MapSet.new())}
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

        {:noreply,
         socket
         |> assign(:deployment, deployment)
         |> assign(:expanded_seed_logs, MapSet.new())
         |> assign(:loaded_seed_logs, MapSet.new())}
    end
  end

  @impl true
  def handle_event("toggle_seed_log", %{"seed_sid" => seed_sid}, socket) do
    expanded_seed_logs = socket.assigns.expanded_seed_logs
    loaded_seed_logs = socket.assigns.loaded_seed_logs

    {expanded_seed_logs, loaded_seed_logs} =
      if expanded_seed_log?(socket.assigns.expanded_seed_logs, seed_sid) do
        {MapSet.delete(expanded_seed_logs, seed_sid), loaded_seed_logs}
      else
        {MapSet.put(expanded_seed_logs, seed_sid), MapSet.put(loaded_seed_logs, seed_sid)}
      end

    {:noreply,
     socket
     |> assign(:expanded_seed_logs, expanded_seed_logs)
     |> assign(:loaded_seed_logs, loaded_seed_logs)}
  end

  defp expanded_seed_log?(expanded_seed_logs, seed_sid) do
    MapSet.member?(expanded_seed_logs, seed_sid)
  end

  defp loaded_seed_log?(loaded_seed_logs, seed_sid) do
    MapSet.member?(loaded_seed_logs, seed_sid)
  end

  defp seed_log_url(deployment_sid, seed_sid) do
    ~p"/deployments/#{deployment_sid}/seeds/#{seed_sid}/log"
  end
end
