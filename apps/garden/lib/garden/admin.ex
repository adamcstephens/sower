defmodule Garden.Admin do
  @moduledoc """
  Admin tools for the garden. Useful on local repl
  """

  require Logger

  import SowerClient.Seed, only: [is_seed_type?: 1]

  alias SowerClient.Admin.Request
  alias SowerClient.Admin.Status

  @doc """
  Dispatch a decoded admin socket request.

  Returns one of `{:ok, message}`, `{:error, message}`, or `{:status, %Status{}}`
  for `Garden.AdminSocket` to encode into reply frames.
  """
  def handle(%Request{kind: "deploy"} = request), do: deploy_request(request)
  def handle(%Request{kind: "reload"}), do: reload()
  def handle(%Request{kind: "status"}), do: status()

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

    {:status, Status.cast!(%{version: version, active_deployments: active})}
  end

  defp deploy_request(%Request{sid: sid, force: force}) when is_binary(sid) do
    case Enum.find(Garden.Storage.read().subscriptions, &(&1.sid == sid)) do
      nil -> {:error, "subscription not found for sid #{sid}"}
      sub -> enqueue(Garden.Socket.deploy(sub, force: force))
    end
  end

  defp deploy_request(%Request{seed_type: seed_type, force: force}) when is_binary(seed_type) do
    enqueue(deploy(seed_type, force: force))
  end

  defp deploy_request(%Request{}) do
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
    seed_type |> String.to_existing_atom() |> deploy()
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
