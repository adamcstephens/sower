defmodule SowerWeb.TreeLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Plant

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage tree records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="tree-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >

        <:actions>
          <.button phx-disable-with="Saving...">Save Tree</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{tree: tree} = assigns, socket) do
    changeset = Plant.change_tree(tree)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"tree" => tree_params}, socket) do
    changeset =
      socket.assigns.tree
      |> Plant.change_tree(tree_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"tree" => tree_params}, socket) do
    save_tree(socket, socket.assigns.action, tree_params)
  end

  defp save_tree(socket, :edit, tree_params) do
    case Plant.update_tree(socket.assigns.tree, tree_params) do
      {:ok, tree} ->
        notify_parent({:saved, tree})

        {:noreply,
         socket
         |> put_flash(:info, "Tree updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_tree(socket, :new, tree_params) do
    case Plant.create_tree(tree_params) do
      {:ok, tree} ->
        notify_parent({:saved, tree})

        {:noreply,
         socket
         |> put_flash(:info, "Tree created successfully")
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
