defmodule SowerWeb.RepositoryLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Forge

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage repository records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="repository-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:url]} type="text" label="Url" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Repository</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{repository: repository} = assigns, socket) do
    changeset = Forge.change_repository(repository)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"repository" => repository_params}, socket) do
    changeset =
      socket.assigns.repository
      |> Forge.change_repository(repository_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"repository" => repository_params}, socket) do
    save_repository(socket, socket.assigns.action, repository_params)
  end

  defp save_repository(socket, :edit, repository_params) do
    case Forge.update_repository(socket.assigns.repository, repository_params) do
      {:ok, repository} ->
        notify_parent({:saved, repository})

        {:noreply,
         socket
         |> put_flash(:info, "Repository updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_repository(socket, :new, repository_params) do
    case Forge.create_repository(repository_params) do
      {:ok, repository} ->
        notify_parent({:saved, repository})

        {:noreply,
         socket
         |> put_flash(:info, "Repository created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
