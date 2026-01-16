defmodule SowerWeb.DeploymentLive.Index do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  alias SowerWeb.Layouts

  import SowerWeb.SowerComponents

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
        <:col :let={{_id, deployment}} label="Result">
          <.result result={deployment.result} />
        </:col>
        <:col :let={{_id, deployment}} label="sid">{deployment.sid}</:col>
        <:col :let={{_id, deployment}} label="completed">{deployment.deployed_at}</:col>
        <:action :let={{_id, deployment}}>
          <div class="sr-only">
            <.link navigate={~p"/deployments/#{deployment}"}>Show</.link>
          </div>
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
     |> stream(:deployments, Orchestration.list_deployments())}
  end

  @impl Phoenix.LiveView
  def handle_info({:deployment, :created, deployment}, socket) do
    # Insert new deployment at the top of the stream
    {:noreply, stream_insert(socket, :deployments, deployment, at: 0)}
  end

  def handle_info({:deployment, :updated, deployment}, socket) do
    # Update existing deployment in the stream
    {:noreply, stream_insert(socket, :deployments, deployment)}
  end
end
