defmodule SowerWeb.SubscriptionLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage subscription records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="subscription-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <:actions>
          <.button phx-disable-with="Saving...">Save Subscription</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{subscription: subscription} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Orchestration.change_subscription(subscription, %{agent: nil}))
     end)}
  end

  @impl true
  def handle_event("validate", %{"subscription" => subscription_params}, socket) do
    changeset =
      Orchestration.change_subscription(socket.assigns.subscription, subscription_params)

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"subscription" => subscription_params}, socket) do
    save_subscription(socket, socket.assigns.action, subscription_params)
  end

  defp save_subscription(socket, :edit, subscription_params) do
    case Orchestration.update_subscription(socket.assigns.subscription, subscription_params) do
      {:ok, subscription} ->
        notify_parent({:saved, subscription})

        {:noreply,
         socket
         |> put_flash(:info, "Subscription updated successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_subscription(socket, :new, subscription_params) do
    case Orchestration.create_subscription(subscription_params) do
      {:ok, subscription} ->
        notify_parent({:saved, subscription})

        {:noreply,
         socket
         |> put_flash(:info, "Subscription created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
