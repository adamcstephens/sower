defmodule Garden.Admin do
  @moduledoc """
  Local garden administration, including bounded deployment-start observation.
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

  Returns `{:ok, message}`, `{:error, message}`, `{:status, %StatusReport{}}`,
  or `{:wait, subscription, command}` for `Garden.AdminSocket` to encode
  into reply frames or observe until execution start.
  """
  def handle(%Deploy{} = command), do: deploy_command(command)

  def handle(%Reload{}), do: reload()
  def handle(%Reregister{}), do: reregister()
  def handle(%Status{}), do: status()

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

  defp deploy_command(%Deploy{sid: sid} = command) when is_binary(sid) do
    case Enum.find(Garden.Storage.read().subscriptions, &(&1.sid == sid)) do
      nil -> {:error, "subscription not found for sid #{sid}"}
      sub -> dispatch_deploy(sub, command)
    end
  end

  defp deploy_command(%Deploy{seed_type: seed_type} = command) when is_binary(seed_type) do
    case subs(seed_type) do
      [sub] -> dispatch_deploy(sub, command)
      [] -> {:error, "subscription not found"}
      _ -> {:error, "multiple subscriptions matched"}
    end
  end

  defp deploy_command(%Deploy{}) do
    {:error, "deploy requires a seed_type or sid"}
  end

  defp dispatch_deploy(sub, %Deploy{wait: true} = command), do: {:wait, sub, command}

  defp dispatch_deploy(sub, %Deploy{wait: false} = command) do
    :ok = Garden.Socket.deploy(sub, force: command.force)
    {:ok, "deployment enqueued"}
  end

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
