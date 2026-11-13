defmodule SowerWeb.ManagedProfilesComponent do
  @moduledoc """
  Operator inventory and explicit operations for subscription-owned managed profiles.

  Inventory is the server's last observation, not proof of current Garden state.
  Pending requests remain pending until Garden acknowledges them. External processes
  are never restarted or stopped by selection or uninstall.
  """
  use SowerWeb, :live_component

  alias Sower.Orchestration.ManagedProfile
  alias SowerClient.Orchestration.ProfileOperation

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    profiles = ManagedProfile.list_for_garden(assigns.garden)

    profiles =
      if assigns[:subscription],
        do: Enum.filter(profiles, &(&1.name == assigns.subscription.name)),
        else: profiles

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:profiles, profiles)
     |> assign_new(:result, fn -> nil end)
     |> assign_new(:error, fn -> nil end)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <section id={@id} class="mt-8 space-y-4">
      <h2 class="text-sm font-semibold">Named managed profiles</h2>
      <p class="text-sm text-content-muted">
        Last reported Garden state; an offline Garden may differ. Download alone does not mean selected.
        Selection does not restart external services. Pin immutable generations until consumers transition.
      </p>
      <.button type="button" phx-click="refresh" phx-target={@myself}>Refresh observation</.button>
      <p :if={@error} role="alert">{@error}</p>
      <div :if={@result} id={"#{@id}-result"} role="status">
        Request {@result.request_id}: {@result.status}
        <p :if={@result.error}>{@result.error}</p>
        <p :if={@result.warning}>{@result.warning}</p>
        <p :for={generation <- @result.affected_generations || []}>
          Affected generation: {generation.generation_id} — {generation.generation_path}
          {if generation.pinned, do: "(pinned; unpin explicitly first)"}
        </p>
        <.button
          :if={@result.status == "preview"}
          type="button"
          phx-click="operate"
          phx-target={@myself}
          phx-value-action="uninstall"
          phx-value-name={@result.profile_name}
          data-confirm="External services are not stopped. Published profile paths will disappear. Continue?"
        >
          Confirm uninstall
        </.button>
      </div>
      <p :if={@profiles == []} class="text-sm text-content-muted">No managed profiles reported.</p>
      <article
        :for={profile <- @profiles}
        id={"profile-#{profile.name}"}
        class="rounded-lg border border-hairline p-4 space-y-3"
      >
        <h3 class="font-semibold">{profile.name} ({profile.seed_type})</h3>
        <p>Published path: <code>{profile.profile_path}</code></p>
        <p>Last observed state: {profile.lifecycle_status || "unknown"}</p>
        <p :if={profile.last_error} role="alert">{profile.last_error}</p>
        <p :if={!profile.retention}>Effective retention: keep all generations.</p>
        <p :if={profile.retention}>
          Effective retention: newest {profile.retention.keep_generations || 0} generations plus
          generations younger than {profile.retention.keep_days || 0} days; selected, pinned, staged and in-flight generations are protected.
        </p>
        <div :for={generation <- profile.generations} class="border-t border-hairline pt-2">
          <p>Generation {generation.generation_number}: <code>{generation.generation_id}</code></p>
          <p>Immutable path: <code>{generation.generation_path}</code></p>
          <p>Artifact: <code>{generation.path}</code></p>
          <p>Seed: {generation.seed_sid || "not reported"}</p>
          <p>
            {if generation.is_current, do: "Selected "}{if generation.is_staged, do: "Staged "}{if generation.pinned,
              do: "Pinned"}
          </p>
          <.button
            :for={action <- ["select", "rollback", "pin", "unpin", "discard"]}
            type="button"
            variant={:secondary}
            phx-click="operate"
            phx-target={@myself}
            phx-value-name={profile.name}
            phx-value-generation_id={generation.generation_id}
            phx-value-action={action}
          >{String.capitalize(action)}</.button>
        </div>
        <.button
          type="button"
          variant={:secondary}
          phx-click="operate"
          phx-target={@myself}
          phx-value-name={profile.name}
          phx-value-action="preview_uninstall"
        >Preview uninstall</.button>
      </article>
      <.button
        :if={assigns[:subscription] && @profiles == []}
        type="button"
        phx-click="operate"
        phx-target={@myself}
        phx-value-action="preview_uninstall"
        phx-value-name={@subscription.name}
      >Preview subscription uninstall</.button>
      <form
        :if={assigns[:subscription] && @subscription.seed_type in ["package", "devshell"]}
        phx-submit="stage"
        phx-target={@myself}
        id={"#{@id}-stage"}
      >
        <label>Seed SID (blank selects latest matching seed)<input type="text" name="seed_sid" /></label>
        <.button disabled={@subscription.uninstall_pending}>Stage without selecting</.button>
      </form>
    </section>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("refresh", _params, socket) do
    result = socket.assigns.result

    result =
      if result && result.status == "pending",
        do: refresh_result(socket.assigns.garden, result),
        else: result

    {:noreply, assign(socket, profiles: visible_profiles(socket), result: result)}
  end

  def handle_event("stage", params, socket) do
    subscription = socket.assigns.subscription

    operation = %ProfileOperation{
      request_id: Ecto.UUID.generate(),
      profile_name: subscription.name,
      action: "stage",
      subscription_sid: subscription.sid,
      seed_sid: blank_to_nil(params["seed_sid"])
    }

    execute(socket, operation)
  end

  def handle_event("operate", params, socket) do
    preview = params["action"] == "preview_uninstall"
    action = if preview, do: "uninstall", else: params["action"]

    operation = %ProfileOperation{
      request_id: Ecto.UUID.generate(),
      profile_name: params["name"],
      action: action,
      generation_id: params["generation_id"],
      preview: preview
    }

    execute(socket, operation)
  end

  defp execute(socket, %ProfileOperation{} = operation) do
    case ManagedProfile.request(socket.assigns.garden, operation) do
      {:ok, result} ->
        {:noreply, assign(socket, result: result, error: nil, profiles: visible_profiles(socket))}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Profile operation failed: #{inspect(reason)}")}
    end
  end

  defp visible_profiles(socket) do
    profiles = ManagedProfile.list_for_garden(socket.assigns.garden)

    case socket.assigns[:subscription] do
      nil -> profiles
      subscription -> Enum.filter(profiles, &(&1.name == subscription.name))
    end
  end

  defp refresh_result(garden, result) do
    case ManagedProfile.operation_result(garden, result.request_id) do
      {:ok, updated} -> updated
      {:error, :not_found} -> result
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
