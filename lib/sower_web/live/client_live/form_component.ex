defmodule SowerWeb.ClientLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Bob

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage client records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="client-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >

        <:actions>
          <.button phx-disable-with="Saving...">Save Client</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{client: client} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Bob.change_client(client))
     end)}
  end

  @impl true
  def handle_event("validate", %{"client" => client_params}, socket) do
    changeset = Bob.change_client(socket.assigns.client, client_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"client" => client_params}, socket) do
    save_client(socket, socket.assigns.action, client_params)
  end

  defp save_client(socket, :edit, client_params) do
    case Bob.update_client(socket.assigns.client, client_params) do
      {:ok, client} ->
        notify_parent({:saved, client})

        {:noreply,
         socket
         |> put_flash(:info, "Client updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_client(socket, :new, client_params) do
    case Bob.create_client(client_params) do
      {:ok, client} ->
        notify_parent({:saved, client})

        {:noreply,
         socket
         |> put_flash(:info, "Client created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
