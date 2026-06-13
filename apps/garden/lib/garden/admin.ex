defmodule Garden.Admin do
  @moduledoc """
  Admin tools for the garden. Useful on local repl
  """

  require Logger

  import SowerClient.Seed, only: [is_seed_type?: 1]

  alias SowerClient.Admin.Deploy
  alias SowerClient.Admin.Reload
  alias SowerClient.Admin.Status
  alias SowerClient.Admin.StatusReport

  @doc """
  Dispatch a decoded admin socket command struct.

  Returns one of `{:ok, message}`, `{:error, message}`, or
  `{:status, %StatusReport{}}` for `Garden.AdminSocket` to encode into reply
  frames.
  """
  def handle(%Deploy{} = command), do: deploy_command(command)
  def handle(%Reload{}), do: reload()
  def handle(%Status{}), do: status()

  @doc """
  Request a service reload, the same path as a SIGHUP.
  """
  def reload do
    Garden.request_reload()
    {:ok, "reload requested"}
  end

  @doc """
  Report the running garden version and any inflight deployments.
  """
  def status do
    version = to_string(Application.spec(:garden, :vsn))
    active = Garden.Socket.active_deployments() |> Map.keys()

    {:status, StatusReport.cast!(%{version: version, active_deployments: active})}
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
