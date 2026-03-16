defmodule SowerWeb.Settings.AccessTokenLive.FormComponent do
  alias Sower.Accounts.AccessToken
  use SowerWeb, :live_component

  alias Sower.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
      </.header>

      <.simple_form
        for={@form}
        id="access_token-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <.input field={@form[:description]} type="text" label="Description" />
        <.input field={@form[:expires_at]} type="date" label="Expiration date" />
        <%= if @action == :edit do %>
          <.input
            field={@form[:regenerate]}
            type="checkbox"
            label="Regenerate"
            disabled={is_force_expires_at_regeneration(@access_token, @form[:expires_at].value)}
          />
        <% end %>

        <.header>
          Permissions
        </.header>
        <.inputs_for :let={perm} field={@form[:permissions]}>
          <input type="hidden" name="access_token[permissions_sort][]" value={perm.index} />
          <.input
            field={perm[:role]}
            type="select"
            options={Sower.Accounts.AccessToken.permission_roles()}
          />
          <.button
            variant={:icon}
            type="button"
            name="access_token[permissions_drop][]"
            value={perm.index}
            phx-click={JS.dispatch("change")}
          >
            <.icon name="hero-x-mark" class="w-6 h-6 relative top-2" />
          </.button>
        </.inputs_for>

        <input type="hidden" name="access_token[permissions_drop][]" />

        <:actions>
          <.button
            variant={:secondary}
            type="button"
            name="access_token[permissions_sort][]"
            value="new"
            phx-click={JS.dispatch("change")}
          >
            add permission
          </.button>
          <.button phx-disable-with="Saving...">Save</.button>
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
      {:ok, access_token} ->
        notify_parent({:saved, access_token})

        {:noreply,
         socket
         |> put_flash(:token, access_token.token)
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_access_token(socket, :new, access_token_params) do
    access_token_params =
      access_token_params
      |> Map.put("user_id", socket.assigns.current_user.id)
      |> Map.put("org_id", socket.assigns.current_user.org_id)

    case Accounts.AccessToken.create(access_token_params) do
      {:ok, access_token} ->
        notify_parent({:saved, access_token})

        {:noreply,
         socket
         |> put_flash(:token, access_token.token)
         |> push_navigate(to: ~p"/settings/access-tokens/#{access_token}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})

  defp is_force_expires_at_regeneration(%AccessToken{} = access_token, %Date{} = new_expires_at) do
    access_token.expires_at != new_expires_at
  end

  defp is_force_expires_at_regeneration(%AccessToken{} = access_token, new_expires_at)
       when is_binary(new_expires_at) do
    access_token.expires_at != new_expires_at |> Date.from_iso8601!()
  end
end
