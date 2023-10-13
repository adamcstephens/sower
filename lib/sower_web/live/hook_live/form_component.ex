defmodule SowerWeb.HookLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Forge

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage hook records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="hook-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:request]} type="text" label="Request" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Hook</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{hook: hook} = assigns, socket) do
    changeset = SCM.change_hook(hook)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"hook" => hook_params}, socket) do
    changeset =
      socket.assigns.hook
      |> SCM.change_hook(hook_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"hook" => hook_params}, socket) do
    save_hook(socket, socket.assigns.action, hook_params)
  end

  defp save_hook(socket, :edit, hook_params) do
    case SCM.update_hook(socket.assigns.hook, hook_params) do
      {:ok, hook} ->
        notify_parent({:saved, hook})

        {:noreply,
         socket
         |> put_flash(:info, "Hook updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_hook(socket, :new, hook_params) do
    case SCM.create_hook(hook_params) do
      {:ok, hook} ->
        notify_parent({:saved, hook})

        {:noreply,
         socket
         |> put_flash(:info, "Hook created successfully")
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
