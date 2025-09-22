defmodule SowerWeb.DeploymentLive.Form do
  use SowerWeb, :live_view

  alias Sower.Orchestration
  alias Sower.Orchestration.Deployment

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage deployment records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="deployment-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:seed_name]} type="text" label="Seed name" />
        <.input field={@form[:seed_type]} type="text" label="Seed type" />
        <footer>
          <.button phx-disable-with="Saving..." variant="primary">Save Deployment</.button>
          <.button navigate={return_path(@return_to, @deployment)}>Cancel</.button>
        </footer>
      </.form>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    deployment = Orchestration.get_deployment!(id)

    socket
    |> assign(:page_title, "Edit Deployment")
    |> assign(:deployment, deployment)
    |> assign(:form, to_form(Orchestration.change_deployment(deployment)))
  end

  defp apply_action(socket, :new, _params) do
    deployment = %Deployment{}

    socket
    |> assign(:page_title, "New Deployment")
    |> assign(:deployment, deployment)
    |> assign(:form, to_form(Orchestration.change_deployment(deployment)))
  end

  @impl true
  def handle_event("validate", %{"deployment" => deployment_params}, socket) do
    changeset = Orchestration.change_deployment(socket.assigns.deployment, deployment_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"deployment" => deployment_params}, socket) do
    save_deployment(socket, socket.assigns.live_action, deployment_params)
  end

  defp save_deployment(socket, :edit, deployment_params) do
    case Orchestration.update_deployment(socket.assigns.deployment, deployment_params) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deployment updated successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, deployment))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_deployment(socket, :new, deployment_params) do
    case Orchestration.create_deployment(deployment_params) do
      {:ok, deployment} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deployment created successfully")
         |> push_navigate(to: return_path(socket.assigns.return_to, deployment))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path("index", _deployment), do: ~p"/deployments"
  defp return_path("show", deployment), do: ~p"/deployments/#{deployment}"
end
