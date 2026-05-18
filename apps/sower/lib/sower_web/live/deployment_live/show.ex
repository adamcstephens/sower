defmodule SowerWeb.DeploymentLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      nav_section={assigns[:nav_section]}
      sidebar_state={assigns[:sidebar_state]}
      crumbs={assigns[:crumbs] || []}
    >
      <.header>
        <div class="flex items-center space-x-2 min-w-0">
          <.deployment_status state={@deployment.state} result={@deployment.result} />
          <span class="truncate" title={@deployment.sid}>{@deployment.sid}</span>
        </div>
        <:actions>
          <.button
            :if={retryable?(@deployment)}
            variant={:secondary}
            type="button"
            phx-click="retry"
            phx-disable-with="Retrying..."
            disabled={@retrying}
          >
            Retry
          </.button>
        </:actions>
      </.header>

      <div class="mt-8 space-y-10">
        <.detail_field label="Completed">
          <.local_datetime datetime={@deployment.deployed_at} user_timezone={@user_timezone} />
        </.detail_field>

        <.detail_field label="Garden">
          <.link
            navigate={~p"/gardens/#{@deployment.garden}"}
            class="hover:text-orange-500 dark:hover:text-orange-400"
          >
            {@deployment.garden.name}
          </.link>
        </.detail_field>

        <section>
          <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 mb-4">Subscriptions</h2>
          <.table
            id="subscriptions"
            rows={@deployment.subscriptions}
            row_click={
              fn subscription ->
                JS.navigate(~p"/gardens/#{@deployment.garden}/subscriptions/#{subscription.sid}")
              end
            }
            header_border={false}
          >
            <:col :let={subscription}>
              {subscription.seed_type}/{subscription.seed_name}
            </:col>
          </.table>
          <p
            :if={@deployment.subscriptions == []}
            class="text-sm text-zinc-500 dark:text-zinc-400 italic"
          >
            No subscriptions.
          </p>
        </section>

        <section>
          <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 mb-4">Seeds</h2>
          <div :if={@deployment.seed_deployments != []} class="space-y-4">
            <article
              :for={sd <- @deployment.seed_deployments}
              id={"seed-log-#{sd.seed.sid}"}
              class="rounded-lg border border-zinc-200/50 dark:border-zinc-700/50 p-4"
            >
              <div
                class={[
                  "flex flex-wrap items-center justify-between gap-2 sm:gap-4",
                  sd.log && "cursor-pointer"
                ]}
                phx-click={sd.log && "toggle_seed_log"}
                phx-value-seed_sid={sd.log && sd.seed.sid}
              >
                <div class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 flex flex-wrap items-center gap-2 min-w-0">
                  <.link
                    navigate={~p"/seeds/#{sd.seed.sid}"}
                    class="hover:text-orange-500 dark:hover:text-orange-400"
                  >
                    {sd.seed.seed_type}/{sd.seed.name}
                  </.link>
                  <span class="text-xs font-normal text-zinc-500 dark:text-zinc-400">
                    {sd.seed.artifact}
                  </span>
                </div>
                <div class="flex items-center gap-2">
                  <.deployment_status
                    :if={sd.result}
                    state={:completed}
                    result={sd.result}
                    compact
                  />
                  <.seed_deployment_status :if={!sd.result} state={sd.state} />
                  <.button
                    :if={sd.log}
                    variant={:secondary}
                    type="button"
                    phx-click="toggle_seed_log"
                    phx-value-seed_sid={sd.seed.sid}
                  >
                    {if expanded_seed_log?(@expanded_seed_logs, sd.seed.sid),
                      do: "Hide log",
                      else: "View log"}
                  </.button>
                </div>
              </div>
              <pre
                :if={sd.log && expanded_seed_log?(@expanded_seed_logs, sd.seed.sid)}
                id={"seed-log-content-#{sd.seed.sid}"}
                class="mt-3 p-3 rounded-md border border-zinc-200 dark:border-zinc-700 bg-zinc-50 dark:bg-zinc-800 text-xs text-zinc-800 dark:text-zinc-200 overflow-x-auto whitespace-pre-wrap"
              >{sd.log}</pre>
            </article>
          </div>
          <p
            :if={@deployment.seed_deployments == []}
            class="text-sm text-zinc-500 dark:text-zinc-400 italic"
          >
            No seeds.
          </p>
        </section>

        <section :if={@deployment.events != []}>
          <h2 class="text-sm font-semibold text-zinc-900 dark:text-zinc-200 mb-4">Activity</h2>
          <div class="space-y-3 text-sm">
            <div
              :for={event <- Enum.sort_by(@deployment.events, & &1.inserted_at, DateTime)}
              class="grid grid-cols-[auto_auto_auto] gap-x-4 items-center justify-start"
            >
              <span class="text-zinc-400 dark:text-zinc-500">
                <.local_datetime datetime={event.inserted_at} user_timezone={@user_timezone} />
              </span>
              <span class="text-zinc-700 dark:text-zinc-300">
                {event_description(event)}
              </span>
              <span class="text-zinc-400 dark:text-zinc-500">
                {event.actor_sid}
              </span>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"sid" => sid}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "deployment:#{sid}")
    end

    {:ok, initialize_socket(socket)}
  end

  def mount(_params, _session, socket) do
    {:ok, initialize_socket(socket)}
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
        deployment =
          Sower.Repo.preload(deployment, [
            :events,
            seed_deployments: :seed,
            subscriptions: [],
            garden: []
          ])

        {:noreply,
         socket
         |> assign(:deployment, deployment)
         |> assign(:expanded_seed_logs, MapSet.new())
         |> assign(:crumbs, [{"Deployments", ~p"/deployments"}, {deployment.sid, nil}])}
    end
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, _event, %Sower.Orchestration.Deployment{} = deployment}, socket) do
    {:noreply, refresh_deployment(socket, deployment.sid)}
  end

  def handle_info({:seed_deployment, :updated}, socket) do
    {:noreply, refresh_deployment(socket, socket.assigns.deployment.sid)}
  end

  @impl true
  def handle_event("toggle_seed_log", %{"seed_sid" => seed_sid}, socket) do
    expanded_seed_logs = socket.assigns.expanded_seed_logs

    expanded_seed_logs =
      if MapSet.member?(expanded_seed_logs, seed_sid) do
        MapSet.delete(expanded_seed_logs, seed_sid)
      else
        MapSet.put(expanded_seed_logs, seed_sid)
      end

    {:noreply, assign(socket, :expanded_seed_logs, expanded_seed_logs)}
  end

  def handle_event("retry", _params, socket) do
    socket = assign(socket, :retrying, true)

    case Orchestration.retry_deployment(socket.assigns.deployment, socket.assigns.current_user.id) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Retry deployment created")
         |> redirect(to: ~p"/deployments/#{deployment.sid}")}

      {:error, :deployment_not_retryable} ->
        {:noreply,
         socket
         |> assign(:retrying, false)
         |> put_flash(:error, "Only successful or failed deployments can be retried")}

      {:error, :retry_in_progress} ->
        {:noreply,
         socket
         |> assign(:retrying, false)
         |> put_flash(:error, "A retry is already in progress for this deployment")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:retrying, false)
         |> put_flash(:error, "Failed to retry deployment")}
    end
  end

  defp expanded_seed_log?(expanded_seed_logs, seed_sid) do
    MapSet.member?(expanded_seed_logs, seed_sid)
  end

  defp retryable?(deployment) do
    deployment.state in [:completed, :stale, :canceled]
  end

  defp initialize_socket(socket) do
    socket
    |> assign(:page_title, "Show Deployment")
    |> assign(:expanded_seed_logs, MapSet.new())
    |> assign(:retrying, false)
  end

  defp event_description(%{event: :created, reason: :user_triggered}), do: "Deployed by user"

  defp event_description(%{event: :created, reason: :schedule_triggered}),
    do: "Deployed by schedule"

  defp event_description(%{event: :created, reason: :realtime_triggered}),
    do: "Deployed by realtime trigger"

  defp event_description(%{event: :created, reason: :retry}), do: "Retried"
  defp event_description(%{event: :created, reason: :user_retry}), do: "Retried by user"
  defp event_description(%{event: :created, reason: :poll_on_connect}), do: "Deployed on connect"
  defp event_description(%{event: :canceled, reason: :superseded}), do: "Canceled — superseded"
  defp event_description(%{event: :canceled, reason: :stale}), do: "Canceled — stale"

  defp refresh_deployment(socket, sid) do
    case Orchestration.get_deployment_sid(sid) do
      nil ->
        socket

      deployment ->
        deployment =
          Sower.Repo.preload(deployment, [
            :events,
            seed_deployments: :seed,
            subscriptions: [],
            garden: []
          ])

        assign(socket, :deployment, deployment)
    end
  end
end
