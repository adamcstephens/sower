defmodule SowerWeb.CacheLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Nix

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage cache records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="cache-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:url]} type="text" label="Url" />
        <.input field={@form[:public_key]} type="text" label="Public key" />
        <:actions>
          <.button phx-disable-with="Saving...">Save Cache</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{cache: cache} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Nix.change_cache(cache))
     end)}
  end

  @impl true
  def handle_event("validate", %{"cache" => cache_params}, socket) do
    changeset = Nix.change_cache(socket.assigns.cache, cache_params)
    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"cache" => cache_params}, socket) do
    save_cache(socket, socket.assigns.action, cache_params)
  end

  defp save_cache(socket, :edit, cache_params) do
    case Nix.update_cache(socket.assigns.cache, cache_params) do
      {:ok, cache} ->
        notify_parent({:saved, cache})

        {:noreply,
         socket
         |> put_flash(:info, "Cache updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_cache(socket, :new, cache_params) do
    case Nix.create_cache(cache_params) do
      {:ok, cache} ->
        notify_parent({:saved, cache})

        {:noreply,
         socket
         |> put_flash(:info, "Cache created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
