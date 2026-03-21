defmodule SowerWeb.DeploymentLive.Index do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  alias SowerWeb.Layouts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <.header>
        Listing Deployments
      </.header>

      <.table
        id="deployments"
        rows={@streams.deployments}
        row_click={fn {_id, deployment} -> JS.navigate(~p"/deployments/#{deployment}") end}
      >
        <:col :let={{_id, deployment}} label="">
          <.deployment_status state={deployment.state} result={deployment.result} />
        </:col>
        <:col :let={{_id, deployment}} label="sid">
          <span
            class="sm:hidden truncate max-w-[8rem] inline-block align-bottom"
            title={deployment.sid}
          >
            {deployment.sid}
          </span>
          <span class="hidden sm:inline">{deployment.sid}</span>
        </:col>
        <:col :let={{_id, deployment}} label="garden">
          {get_in(deployment.garden.name) || "-"}
        </:col>
        <:col :let={{_id, deployment}} label="completed" hide_on={:sm}>
          <.local_datetime datetime={deployment.deployed_at} user_timezone={@user_timezone} />
        </:col>
        <:action :let={{_id, deployment}}>
          <.button
            :if={retryable?(deployment)}
            variant={:secondary}
            type="button"
            phx-click="retry"
            phx-value-sid={deployment.sid}
            phx-stop-propagation
            phx-disable-with="Retrying..."
            class="hidden sm:inline"
            disabled={@retrying_deployment_sid == deployment.sid}
          >
            Retry
          </.button>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Sower.PubSub, "deployments")
    end

    {:ok,
     socket
     |> assign(:page_title, "Listing Deployments")
     |> assign(:retrying_deployment_sid, nil)
     |> stream(:deployments, Orchestration.list_deployments() |> Sower.Repo.preload([:garden]))}
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, :created, deployment}, socket) do
    deployment = Sower.Repo.preload(deployment, [:garden])

    # Insert new deployment at the top of the stream
    {:noreply, stream_insert(socket, :deployments, deployment, at: 0)}
  end

  def handle_info({:deployment, :updated, deployment}, socket) do
    deployment = Sower.Repo.preload(deployment, [:garden])

    # Update existing deployment in the stream
    {:noreply, stream_insert(socket, :deployments, deployment)}
  end

  @impl true
  def handle_event("retry", %{"sid" => sid}, socket) do
    deployment = Orchestration.get_deployment_sid(sid)

    cond do
      is_nil(deployment) ->
        {:noreply, put_flash(socket, :error, "Deployment not found")}

      not retryable?(deployment) ->
        {:noreply,
         socket
         |> assign(:retrying_deployment_sid, nil)
         |> put_flash(:error, "Only successful or failed deployments can be retried")}

      true ->
        socket = assign(socket, :retrying_deployment_sid, sid)

        case Orchestration.retry_deployment(deployment, socket.assigns.current_user.id) do
          {:ok, _new_deployment} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment_sid, nil)
             |> put_flash(:info, "Retry deployment created")}

          {:error, :retry_in_progress} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment_sid, nil)
             |> put_flash(:error, "A retry is already in progress for this deployment")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:retrying_deployment_sid, nil)
             |> put_flash(:error, "Failed to retry deployment")}
        end
    end
  end

  defp retryable?(deployment) do
    deployment.state in [:completed, :stale]
  end
end
