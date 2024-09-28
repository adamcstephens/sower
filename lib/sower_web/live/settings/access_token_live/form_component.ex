defmodule SowerWeb.Settings.AccessTokenLive.FormComponent do
  use SowerWeb, :live_component

  alias Sower.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        <%= @title %>
        <:subtitle>Use this form to manage access_token records in your database.</:subtitle>
      </.header>

      <.simple_form
        for={@form}
        id="access_token-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:description]} type="text" />
        <.input field={@form[:expires_at]} value={Date.utc_today() |> Date.add(1)} type="date" />

        <:actions>
          <.button phx-disable-with="Saving...">Save Access token</.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  @impl true
  def update(%{access_token: access_token} = assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:form, fn ->
       to_form(Accounts.AccessToken.changeset(access_token))
     end)}
  end

  @impl true
  def handle_event("validate", %{"access_token" => access_token_params}, socket) do
    changeset =
      Accounts.AccessToken.changeset(socket.assigns.access_token, access_token_params)

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"access_token" => access_token_params}, socket) do
    save_access_token(socket, socket.assigns.action, access_token_params)
  end

  defp save_access_token(socket, :edit, access_token_params) do
    case Accounts.AccessToken.update(socket.assigns.access_token, access_token_params) do
      {:ok, access_token, token} ->
        notify_parent({:saved, access_token})

        {:noreply,
         socket
         |> put_flash(:token, token)
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_access_token(socket, :new, access_token_params) do
    access_token_params = Map.put(access_token_params, "user_id", socket.assigns.current_user.id)

    case Accounts.AccessToken.create(access_token_params) do
      {:ok, access_token, token} ->
        notify_parent({:saved, access_token})

        {:noreply,
         socket
         |> put_flash(:token, token)
         |> push_navigate(to: ~p"/settings/access-tokens/#{access_token.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
