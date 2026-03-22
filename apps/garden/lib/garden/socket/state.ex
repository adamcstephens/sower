defmodule Garden.Socket.State do
  @moduledoc """
  Pure state transition functions for Garden.Socket.

  Each function takes relevant state and returns a result without
  performing side effects. The socket callbacks are thin wrappers
  that call these functions and execute the returned effects.
  """

  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.DeploymentRequest
  alias SowerClient.Orchestration.DeploymentResult
  alias SowerClient.Orchestration.Subscription

  def build_seed_report(
        subscriptions,
        collect_profiles_fun \\ &Garden.Profile.collect_profiles_for_subscriptions/1
      ) do
    report = collect_profiles_fun.(subscriptions)

    if not Enum.empty?(subscriptions) and Enum.empty?(report.profiles) do
      :no_profiles
    else
      {:report, report}
    end
  end

  def build_deployment_request(sid, force?) do
    payload = %{subscription_sids: [sid]}

    payload =
      if force? do
        Map.put(payload, :force, true)
      else
        payload
      end

    DeploymentRequest.new(payload)
  end

  def merge_subscriptions(config_subscriptions, registered) do
    sid_map =
      registered
      |> Enum.map(&Subscription.cast!/1)
      |> Map.new(&{{&1.seed_name, &1.seed_type}, &1.sid})

    config_subscriptions
    |> Enum.map(fn sub ->
      case Map.get(sid_map, {sub.seed_name, sub.seed_type}) do
        nil -> nil
        sid -> %{sub | sid: sid}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def poll_on_connect_subscriptions(subscriptions) do
    Enum.filter(subscriptions, & &1.poll_on_connect)
  end

  def complete_deployment(sid, result, active_deployments) do
    case Map.get(active_deployments, sid) do
      nil ->
        :not_found

      deployment ->
        {:ok, deployment_result} =
          DeploymentResult.cast(%{
            request_id: deployment.request_id,
            deployment_sid: deployment.sid,
            result: result,
            deployed_at: DateTime.utc_now() |> DateTime.to_iso8601()
          })

        {:ok, deployment_result, Map.delete(active_deployments, sid)}
    end
  end

  def lookup_deployment(sid, active_deployments) do
    case Map.get(active_deployments, sid) do
      nil -> :not_found
      deployment -> {:ok, deployment}
    end
  end

  def receive_deployment(%Deployment{skipped: true}, _active_deployments) do
    :skipped
  end

  def receive_deployment(%Deployment{} = deployment, active_deployments) do
    if Map.has_key?(active_deployments, deployment.sid) do
      :duplicate
    else
      {:enqueue, Map.put(active_deployments, deployment.sid, deployment)}
    end
  end
end
