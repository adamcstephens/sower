defmodule Garden.Socket.Lifecycle do
  @moduledoc """
  Lifecycle transitions and message preparation for Garden.Socket.

  Profile report preparation reads filesystem state through the profile collector;
  socket callbacks handle transport and execute the returned lifecycle actions.
  """

  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.DeploymentRequest
  alias SowerClient.Orchestration.DeploymentResult
  alias SowerClient.Orchestration.Subscription
  alias SowerClient.Orchestration.Subscription.Policy

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

  @default_backoff [200, 500, 1_000, 2_000, 5_000, 15_000, 30_000, 60_000, 120_000, 300_000]

  def default_backoff, do: @default_backoff

  def reconnect_delay(counter, backoff_times \\ @default_backoff) do
    Enum.at(backoff_times, counter, List.last(backoff_times))
  end

  @doc """
  Decide what to do after the server rejected the garden's existing credentials.

  A client the server does not recognise is the only rejection re-registration
  could repair, and that is an operator action; every other rejection is
  transient from the garden's point of view.
  """
  def rejection_action({:server_rejected, _status, :unknown_client}), do: :await_operator
  def rejection_action(_reason), do: :retry

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
      |> Map.new(&{&1.name, &1.sid})

    config_subscriptions
    |> Enum.map(fn sub ->
      case Map.get(sid_map, sub.name) do
        nil -> nil
        sid -> %{sub | sid: sid}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def poll_on_connect_subscriptions(subscriptions) do
    now = DateTime.utc_now()

    Enum.filter(subscriptions, fn sub ->
      case Policy.evaluate(sub.policy, :poll_on_connect, now, sub.seed_type, sub.timezone) do
        {:allow, _} -> true
        _ -> false
      end
    end)
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

  def should_reload?(active_deployments, take_pending_reload) do
    map_size(active_deployments) == 0 and take_pending_reload.()
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

  def payload_for_peer(payload, true), do: payload
  def payload_for_peer(%DateTime{} = value, false), do: value

  def payload_for_peer(%module{} = payload, false) do
    drop =
      case module do
        SowerClient.Orchestration.Subscription -> [:retention]
        SowerClient.Orchestration.GardenReport -> [:capabilities]
        SowerClient.Orchestration.GardenSeedsReport -> [:complete, :failed_profile_paths]
        SowerClient.Orchestration.GardenSeedProfile -> [:name, :subscription_sid, :seed_type]
        SowerClient.Orchestration.SeedDeploymentLog -> [:subscription_sid]
        SowerClient.Orchestration.SeedDeploymentStatus -> [:subscription_sid]
        SowerClient.Orchestration.SeedDeploymentResult -> [:subscription_sid]
        _ -> []
      end

    payload
    |> Map.from_struct()
    |> Map.drop(drop)
    |> Map.new(fn {key, value} -> {key, payload_for_peer(value, false)} end)
  end

  def payload_for_peer(payload, false) when is_list(payload),
    do: Enum.map(payload, &payload_for_peer(&1, false))

  def payload_for_peer(payload, false), do: payload
end
