defmodule Garden.Socket.Lifecycle do
  @moduledoc """
  Lifecycle transitions and explicitly addressed profile-operation dispatch for
  Garden.Socket.

  Deployment transitions are pure. Profile operations delegate serialized durable
  mutations to Garden.ManagedProfiles and translate their observed outcomes into
  protocol acknowledgements; uninstall previews never acknowledge completed removal.
  """

  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.DeploymentRequest
  alias SowerClient.Orchestration.DeploymentResult
  alias SowerClient.Orchestration.Subscription
  alias SowerClient.Orchestration.Subscription.Policy

  def payload_for_peer(%_{} = message, true), do: message

  def payload_for_peer(%_{} = message, false) do
    message |> Map.from_struct() |> Map.delete(:subscription_sid)
  end

  def build_seed_report(
        subscriptions,
        collect_profiles_fun \\ &Garden.Profile.collect_profiles_for_subscriptions/1
      ) do
    report = collect_profiles_fun.(subscriptions)

    if is_nil(report.complete) and not Enum.empty?(subscriptions) and Enum.empty?(report.profiles) do
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

  def merge_subscriptions(config_subscriptions, registered, managed_profiles_supported \\ false) do
    registered_by_destination =
      registered
      |> Enum.map(&Subscription.cast!/1)
      |> Map.new(&{{&1.name, &1.seed_name, &1.seed_type}, &1})

    config_subscriptions
    |> Enum.map(fn sub ->
      case Map.get(registered_by_destination, {sub.name, sub.seed_name, sub.seed_type}) do
        nil ->
          nil

        registered ->
          if managed_profiles_supported and sub.seed_type in ["package", "devshell"] do
            %{
              sub
              | sid: registered.sid,
                retention: registered.retention,
                uninstall_pending: registered.uninstall_pending
            }
          else
            %{sub | sid: registered.sid}
          end
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  def refresh_managed_subscriptions(subscriptions, snapshot, removed_sids \\ []) do
    Enum.reduce_while(snapshot, {:ok, []}, fn attributes, {:ok, managed} ->
      case Subscription.cast(attributes) do
        {:ok, %Subscription{seed_type: type} = subscription}
        when type in ["package", "devshell"] ->
          if subscription.sid in removed_sids do
            {:cont, {:ok, managed}}
          else
            {:cont, {:ok, [subscription | managed]}}
          end

        {:ok, _subscription} ->
          {:halt, {:error, :not_managed_subscription}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, managed} ->
        Enum.reduce_while(Enum.reverse(managed), {:ok, subscriptions}, fn incoming,
                                                                          {:ok, current} ->
          index = Enum.find_index(current, &(&1.name == incoming.name))

          case {index, incoming.origin} do
            {nil, "operator"} ->
              {:cont, {:ok, current ++ [incoming]}}

            {nil, _declared} ->
              {:cont, {:ok, current}}

            {index, origin} ->
              existing = Enum.at(current, index)

              cond do
                origin == "operator" and existing.origin == "operator" and
                    existing.sid == incoming.sid ->
                  {:cont, {:ok, List.replace_at(current, index, incoming)}}

                origin != "operator" and existing.origin != "operator" and
                    {existing.sid, existing.seed_name, existing.seed_type} ==
                      {incoming.sid, incoming.seed_name, incoming.seed_type} ->
                  updated = %{
                    existing
                    | retention: incoming.retention,
                      uninstall_pending: incoming.uninstall_pending
                  }

                  {:cont, {:ok, List.replace_at(current, index, updated)}}

                true ->
                  {:halt, {:error, {:ownership_conflict, incoming.name}}}
              end
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
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

  def profile_operation(%SowerClient.Orchestration.ProfileOperation{} = operation) do
    result =
      case operation.action do
        "inspect" ->
          Garden.ManagedProfiles.inspect(operation.profile_name)

        "uninstall" ->
          binding =
            Enum.find(Garden.Storage.read().subscriptions, &(&1.name == operation.profile_name))

          cond do
            is_nil(operation.subscription_sid) ->
              {:error, :missing_profile_binding}

            binding && binding.sid != operation.subscription_sid ->
              {:error, :ownership_conflict}

            true ->
              result =
                Garden.ManagedProfiles.uninstall(operation.profile_name,
                  preview: operation.preview,
                  expected_subscription_sid: operation.subscription_sid
                )

              if result == {:ok, :uninstalled} and not operation.preview and binding do
                subscriptions = Garden.Storage.remove_subscription(binding.name, binding.sid)
                Garden.Scheduler.refresh_subscriptions(subscriptions)
              end

              result
          end

        action when action in ["select", "rollback", "pin", "unpin", "discard"] ->
          apply(Garden.ManagedProfiles, String.to_existing_atom(action), [
            operation.profile_name,
            operation.generation_id
          ])

        "stage" ->
          {:error, :stage_requires_server_deployment}
      end

    profile_operation_result(operation, result)
  end

  def profile_operation_result(%SowerClient.Orchestration.ProfileOperation{} = operation, result) do
    attributes = %{
      request_id: operation.request_id,
      profile_name: operation.profile_name,
      warning:
        if(operation.action == "uninstall",
          do: "External services are not stopped; published and generation paths will disappear."
        )
    }

    attributes =
      case result do
        {:ok, :uninstalled} ->
          Map.put(attributes, :status, "completed")

        {:ok, %SowerClient.Orchestration.GardenSeedProfile{} = profile} ->
          Map.merge(attributes, %{
            status:
              if(operation.action == "uninstall" and operation.preview,
                do: "preview",
                else: "completed"
              ),
            profile: profile,
            affected_generations: if(operation.preview, do: profile.generations, else: [])
          })

        {:error, :pinned_generations} ->
          Map.merge(attributes, %{status: "blocked", error: "pinned_generations"})

        {:error, reason} ->
          Map.merge(attributes, %{status: "failed", error: inspect(reason)})
      end

    SowerClient.Orchestration.ProfileOperationResult.cast!(attributes)
  end
end
