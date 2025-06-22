defmodule SowerWeb.AgentLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage agent records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="agent-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Agent</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{agent: agent} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Orchestration.change_agent(agent))
     end)}
  end

  @impl true
  def handle_event("validate", %{"agent" => agent_params}, socket) do
    changeset = Orchestration.change_agent(socket.assigns.agent, agent_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"agent" => agent_params}, socket) do
    save_agent(socket, socket.assigns.action, agent_params)
  end

  defp save_agent(socket, :edit, agent_params) do
    case Orchestration.update_agent(socket.assigns.agent, agent_params) do
      {:ok, agent} ->
        notify_parent({:saved, agent})

        {:noreply,
         socket
         |> put_flash(:info, "Agent updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_agent(socket, :new, agent_params) do
    case Orchestration.create_agent(agent_params) do
      {:ok, agent} ->
        notify_parent({:saved, agent})

        {:noreply,
         socket
         |> put_flash(:info, "Agent created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
