defmodule Garden.Admin do
  @moduledoc """
  Dispatches authenticated local operator commands, including offline managed-profile
  inventory and generation operations. Staging uses the server deployment-policy
  boundary; uninstall previews unless explicitly confirmed.
  """

  require Logger

  import SowerClient.Seed, only: [is_seed_type?: 1]

  alias SowerClient.Admin.Deploy
  alias SowerClient.Admin.Reload
  alias SowerClient.Admin.Reregister
  alias SowerClient.Admin.Status
  alias SowerClient.Admin.StatusReport

  @doc """
  Dispatch a decoded admin socket command struct.

  Returns one of `{:ok, message}`, `{:error, message}`, or
  `{:status, %StatusReport{}}`, or `{:profile, %ProfileOperationResult{}}` for
  `Garden.AdminSocket` to encode into reply frames.
  """
  def handle(%Deploy{} = command), do: deploy_command(command)
  def handle(%Reload{}), do: reload()
  def handle(%Reregister{}), do: reregister()
  def handle(%Status{}), do: status()

  def handle({request_id, %SowerClient.Admin.Profile{} = command}) do
    profile(command, request_id)
  end

  def profile(%SowerClient.Admin.Profile{action: :list}, request_id) do
    result =
      case Garden.ManagedProfiles.list() do
        {:ok, profiles} ->
          SowerClient.Orchestration.ProfileOperationResult.cast!(%{
            request_id: request_id,
            status: "completed",
            profiles: profiles
          })

        {:error, reason} ->
          SowerClient.Orchestration.ProfileOperationResult.cast!(%{
            request_id: request_id,
            status: "failed",
            error: inspect(reason)
          })
      end

    {:profile, result}
  end

  def profile(%SowerClient.Admin.Profile{} = command, request_id) do
    operation =
      command
      |> Map.from_struct()
      |> Map.put(:request_id, request_id)
      |> Map.put(:action, Atom.to_string(command.action))
      |> SowerClient.Orchestration.ProfileOperation.cast!()

    binding =
      Enum.find(Garden.Storage.read().subscriptions, &(&1.name == command.profile_name))

    operation =
      cond do
        binding ->
          %{operation | subscription_sid: binding.sid}

        command.action == :uninstall ->
          case Garden.ManagedProfiles.inspect(command.profile_name) do
            {:ok, profile} -> %{operation | subscription_sid: profile.subscription_sid}
            {:error, _reason} -> operation
          end

        true ->
          operation
      end

    result =
      if command.action == :stage or
           (command.action == :uninstall and not command.preview and binding) do
        case Garden.Socket.profile_operation(operation) do
          {:ok, result} ->
            result

          {:error, reason} ->
            Garden.Socket.Lifecycle.profile_operation_result(operation, {:error, reason})
        end
      else
        Garden.Socket.Lifecycle.profile_operation(operation)
      end

    result =
      if command.action == :uninstall and command.preview do
        %{
          result
          | warning: "Local inventory preview; server state may have changed. " <> result.warning
        }
      else
        result
      end

    {:profile, result}
  end

  @doc """
  Request a service reload, the same path as a SIGHUP.
  """
  def reload do
    Garden.request_reload()
    {:ok, "reload requested"}
  end

  @doc """
  Discard the garden identity and enroll a new one, the operator recovery path.
  """
  def reregister do
    case Garden.Socket.reregister() do
      {:ok, garden_sid} ->
        {:ok, "re-registered as #{garden_sid}"}

      {:error, :not_running} ->
        {:error, "garden socket is not running"}

      {:error, reason} ->
        {:error, "re-registration failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Report the running garden version, inflight and pending deployments, and whether
  the garden is waiting on an operator to re-register it.
  """
  def status do
    version = to_string(Application.spec(:garden, :vsn))
    active = Garden.Socket.active_deployments() |> Map.keys()

    {:status,
     StatusReport.cast!(%{
       version: version,
       active_deployments: active,
       pending_deployments: Garden.Socket.pending_deployments(),
       credentials_rejected_at: Garden.Storage.read().credentials_rejected_at
     })}
  end

  defp deploy_command(%Deploy{sid: sid, force: force}) when is_binary(sid) do
    case Enum.find(Garden.Storage.read().subscriptions, &(&1.sid == sid)) do
      nil -> {:error, "subscription not found for sid #{sid}"}
      sub -> enqueue(Garden.Socket.deploy(sub, force: force))
    end
  end

  defp deploy_command(%Deploy{seed_type: seed_type, force: force}) when is_binary(seed_type) do
    enqueue(deploy(seed_type, force: force))
  end

  defp deploy_command(%Deploy{}) do
    {:error, "deploy requires a seed_type or sid"}
  end

  defp enqueue(:ok), do: {:ok, "deployment enqueued"}
  defp enqueue({:error, :subscription_not_found}), do: {:error, "subscription not found"}
  defp enqueue({:error, :too_many_results}), do: {:error, "multiple subscriptions matched"}

  def subs(seed_type) do
    Garden.Storage.read().subscriptions
    |> Enum.filter(&(&1.seed_type == seed_type))
  end

  def deploy(seed_type) when is_atom(seed_type) do
    seed_type |> Atom.to_string() |> deploy()
  end

  def deploy(seed_type) when is_seed_type?(seed_type) do
    deploy(seed_type, [])
  end

  def deploy(seed_type, opts) when is_seed_type?(seed_type) do
    force? = Keyword.get(opts, :force, false)

    case subs(seed_type) do
      [] ->
        Logger.error(msg: "nixos subscription not found")
        {:error, :subscription_not_found}

      [sub] ->
        Garden.Socket.deploy(sub, force: force?)

      [_ | _] ->
        Logger.error(msg: "too many nixos subscriptions found")
        {:error, :too_many_results}
    end
  end
end
