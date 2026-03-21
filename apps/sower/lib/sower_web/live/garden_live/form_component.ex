defmodule SowerWeb.GardenLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage garden records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="garden-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Garden</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{garden: garden} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Orchestration.change_garden(garden))
     end)}
  end

  @impl true
  def handle_event("validate", %{"garden" => garden_params}, socket) do
    changeset = Orchestration.change_garden(socket.assigns.garden, garden_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"garden" => garden_params}, socket) do
    save_garden(socket, socket.assigns.action, garden_params)
  end

  defp save_garden(socket, :edit, garden_params) do
    case Orchestration.update_garden(socket.assigns.garden, garden_params) do
      {:ok, garden} ->
        notify_parent({:saved, garden})

        {:noreply,
         socket
         |> put_flash(:info, "Garden updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_garden(socket, :new, garden_params) do
    case Orchestration.create_garden(garden_params) do
      {:ok, garden} ->
        notify_parent({:saved, garden})

        {:noreply,
         socket
         |> put_flash(:info, "Garden created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
