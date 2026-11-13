defmodule SowerWeb.SubscriptionLive.FormComponent do
  use SowerWeb, :live_component

  @moduledoc "Subscription editing, including optional managed-profile retention."

  alias Sower.Orchestration

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.header>
        {@title}
        <:subtitle>Use this form to manage subscription records in your database.</:subtitle>
      </.header>
      <p :if={@save_error} role="alert" id="subscription-save-error">{@save_error}</p>

      <.simple_form
        for={@form}
        id="subscription-form"
        phx-target={@myself}
        phx-change="validate"
        phx-submit="save"
      >
        <div :if={@action == :new}>
          <.input field={@form[:name]} type="text" label="Subscription / profile name" required />
          <.input field={@form[:seed_name]} type="text" label="Seed name" required />
          <.input
            field={@form[:seed_type]}
            type="select"
            label="Seed type"
            options={SowerClient.Seed.seed_types()}
            prompt="Choose a seed type"
            required
          />
        </div>
        <fieldset :if={@form[:seed_type].value in ["package", "devshell"]}>
          <legend>Managed profile retention</legend>
          <p :if={@subscription.origin in [nil, "declared"]}>
            Declared subscription: a retention override remains effective until the declared
            retention value changes. Subscription origin and binding are not changed by this form.
          </p>
          <input type="hidden" name="subscription[retention_enabled]" value="false" />
          <label>
            <input
              type="checkbox"
              name="subscription[retention_enabled]"
              value="true"
              checked={not is_nil(@form[:retention].value)}
            /> Enable retention (unchecked keeps all generations)
          </label>
          <label>
            Newest generations
            <input
              type="number"
              min="0"
              name="subscription[retention][keep_generations]"
              value={get_in(@form[:retention].value || %{}, ["keep_generations"])}
            />
          </label>
          <label>
            Minimum age in days
            <input
              type="number"
              min="0"
              name="subscription[retention][keep_days]"
              value={get_in(@form[:retention].value || %{}, ["keep_days"])}
            />
          </label>
          <p>Set at least one limit. Count and age keep sets are combined. Selected, pinned,
            staged and in-flight generations are protected. Cleanup runs daily and after updates;
            releasing roots does not immediately reclaim disk space.</p>
          <p :for={{message, _opts} <- @form[:retention].errors} role="alert">{message}</p>
        </fieldset>
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
     |> assign_new(:save_error, fn -> nil end)
     |> assign_new(:form, fn ->
       to_form(Orchestration.change_subscription(subscription, %{garden: nil}))
     end)}
  end

  @impl true
  def handle_event("validate", %{"subscription" => subscription_params}, socket) do
    subscription_params = retention_params(subscription_params)

    changeset =
      Orchestration.change_subscription(socket.assigns.subscription, subscription_params)

    {:noreply, assign(socket, form: to_form(changeset, action: :validate), save_error: nil)}
  end

  def handle_event("save", %{"subscription" => subscription_params}, socket) do
    subscription_params = retention_params(subscription_params)
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
    subscription_params =
      Map.put(subscription_params, "garden_id", socket.assigns.subscription.garden_id)

    case Orchestration.create_subscription(subscription_params) do
      {:ok, subscription} ->
        notify_parent({:saved, subscription})

        {:noreply,
         socket
         |> put_flash(:info, "Subscription created successfully")
         |> push_patch(to: socket.assigns.patch)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      {:error, :ownership_conflict} ->
        {:noreply,
         assign(
           socket,
           :save_error,
           "This profile name belongs to a declared subscription; it cannot be taken over."
         )}

      {:error, :uninstall_pending} ->
        {:noreply,
         assign(
           socket,
           :save_error,
           "This profile is pending uninstall. Wait for Garden acknowledgement before recreating it."
         )}
    end
  end

  defp retention_params(%{"retention_enabled" => "false"} = params) do
    params |> Map.delete("retention_enabled") |> Map.put("retention", nil)
  end

  defp retention_params(%{"retention_enabled" => "true"} = params) do
    retention =
      params
      |> Map.fetch!("retention")
      |> Map.reject(fn {_key, value} -> value == "" end)
      |> Map.new(fn {key, value} ->
        parsed =
          case Integer.parse(value) do
            {integer, ""} -> integer
            _ -> value
          end

        {key, parsed}
      end)

    params |> Map.delete("retention_enabled") |> Map.put("retention", retention)
  end

  defp retention_params(params), do: params

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
