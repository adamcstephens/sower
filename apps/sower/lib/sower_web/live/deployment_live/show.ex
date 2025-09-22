defmodule SowerWeb.DeploymentLive.Show do
  use SowerWeb, :live_view

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Deployment {@deployment.id}
        <:subtitle>This is a deployment record from your database.</:subtitle>
        <:actions>
          <.button navigate={~p"/deployments"}>
            <.icon name="hero-arrow-left" />
          </.button>
          <.button variant="primary" navigate={~p"/deployments/#{@deployment}/edit?return_to=show"}>
            <.icon name="hero-pencil-square" /> Edit deployment
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="sid">{@deployment.sid}</:item>
      </.list>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"sid" => sid}, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Show Deployment")
     |> assign(:deployment, Orchestration.get_deployment_sid!(sid))}
  end
end
