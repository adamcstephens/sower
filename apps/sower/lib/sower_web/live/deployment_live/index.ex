defmodule SowerWeb.DeploymentLive.Index do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  alias SowerWeb.Layouts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Listing Deployments
        <:actions>
          <.button variant="primary" navigate={~p"/deployments/new"}>
            <.icon name="hero-plus" /> New Deployment
          </.button>
        </:actions>
      </.header>

      <.table
        id="deployments"
        rows={@streams.deployments}
        row_click={fn {_id, deployment} -> JS.navigate(~p"/deployments/#{deployment}") end}
      >
        <:col :let={{_id, deployment}} label="Seed type">{deployment.sid}</:col>
        <:action :let={{_id, deployment}}>
          <div class="sr-only">
            <.link navigate={~p"/deployments/#{deployment}"}>Show</.link>
          </div>
          <.link navigate={~p"/deployments/#{deployment}/edit"}>Edit</.link>
        </:action>
        <:action :let={{id, deployment}}>
          <.link
            phx-click={JS.push("delete", value: %{id: deployment.id}) |> hide("##{id}")}
            data-confirm="Are you sure?"
          >
            Delete
          </.link>
        </:action>
      </.table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Listing Deployments")
     |> stream(:deployments, Orchestration.list_deployments())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    deployment = Orchestration.get_deployment!(id)
    {:ok, _} = Orchestration.delete_deployment(deployment)

    {:noreply, stream_delete(socket, :deployments, deployment)}
  end
end
