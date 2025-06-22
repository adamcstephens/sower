defmodule SowerWeb.Forge.ConnectionLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Forge

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage connection records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="connection-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:url]} type="text" label="URL" />
        <.input
          field={@form[:type]}
          type="select"
          label="Type"
          prompt="Choose a value"
          options={Ecto.Enum.values(Sower.Forge.Connection, :type)}
        />
        <.input field={@form[:client_id]} type="text" label="Client" />
        <.input field={@form[:client_secret]} type="text" label="Client secret" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Connection</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{connection: connection} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Forge.change_connection(connection))
     end)}
  end

  @impl true
  def handle_event("validate", %{"connection" => connection_params}, socket) do
    changeset = Forge.change_connection(socket.assigns.connection, connection_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"connection" => connection_params}, socket) do
    save_connection(socket, socket.assigns.action, connection_params)
  end

  defp save_connection(socket, :edit, connection_params) do
    case Forge.update_connection(socket.assigns.connection, connection_params) do
      {:ok, connection} ->
        notify_parent({:saved, connection})

        {:noreply,
         socket
         |> put_flash(:info, "Connection updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_connection(socket, :new, connection_params) do
    case Forge.create_connection(connection_params) do
      {:ok, connection} ->
        notify_parent({:saved, connection})

        {:noreply,
         socket
         |> put_flash(:info, "Connection created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
