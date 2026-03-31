defmodule Sower.Orchestration do
  @moduledoc """
  The Orchestration context.
  """

  alias Sower.Orchestration.Garden
  alias Sower.Orchestration.GardenSeedGeneration
  alias Sower.Orchestration.Deployment
  alias Sower.Orchestration.Seed
  alias Sower.Orchestration.Subscription

  # Garden delegates
  defdelegate change_garden(garden, attrs \\ %{}), to: Garden
  defdelegate create_garden(attrs \\ %{}), to: Garden
  defdelegate delete_garden(garden), to: Garden
  defdelegate get_garden!(id), to: Garden
  defdelegate get_garden(hello, socket), to: Garden
  defdelegate get_garden_local_sid!(local_sid), to: Garden
  defdelegate get_garden_local_sid(local_sid), to: Garden
  defdelegate get_garden_sid!(sid), to: Garden
  defdelegate get_garden_sid(sid), to: Garden
  defdelegate list_gardens(), to: Garden
  defdelegate list_gardens_with_latest_deployment(), to: Garden
  defdelegate list_gardens_flop(params \\ %{}), to: Garden
  defdelegate update_garden(garden, attrs), to: Garden

  # Subscription delegates
  defdelegate change_subscription(subscription, attrs \\ %{}), to: Subscription
  defdelegate create_subscription(attrs \\ %{}), to: Subscription
  defdelegate delete_subscription(subscription), to: Subscription
  defdelegate find_subscription(seed), to: Subscription
  defdelegate get_subscription!(id), to: Subscription
  defdelegate get_subscription_sid!(sid), to: Subscription
  defdelegate get_subscription_sid(sid), to: Subscription
  defdelegate get_subscription_sid_with_deployments!(sid), to: Subscription
  defdelegate get_subscription_sid_with_deployments(sid), to: Subscription
  defdelegate get_subscription_sids(sids), to: Subscription
  defdelegate list_subscriptions(), to: Subscription
  defdelegate list_subscriptions_for_garden(garden), to: Subscription
  defdelegate register_subscription(req, garden_id), to: Subscription
  defdelegate sync_subscriptions(subscriptions, garden_id), to: Subscription
  defdelegate update_subscription(subscription, attrs), to: Subscription
  defdelegate catch_up_overdue_schedules(garden, opts \\ []), to: Subscription

  # Deployment delegates
  defdelegate change_deployment(deployment, attrs \\ %{}), to: Deployment
  defdelegate create_deployment(attrs \\ %{}), to: Deployment
  defdelegate delete_deployment(deployment), to: Deployment
  defdelegate deploy_subscription(subscription, opts \\ []), to: Deployment
  defdelegate finalize_stale_deployments(opts \\ []), to: Deployment
  defdelegate get_deployment!(id), to: Deployment
  defdelegate get_deployment_sid!(sid), to: Deployment
  defdelegate get_deployment_sid(sid), to: Deployment
  defdelegate handle_deployment_request(request, garden), to: Deployment
  defdelegate list_deployments(), to: Deployment
  defdelegate list_deployments(garden, opts \\ []), to: Deployment
  defdelegate list_matching_seeds(subscription, limit \\ 10), to: Deployment

  defdelegate list_matching_seeds_enriched(subscription, garden_id, params),
    to: Seed,
    as: :list_matching_enriched

  defdelegate list_unresolved_deployments_for_garden(garden, opts \\ []), to: Deployment
  defdelegate match_seed(subscription), to: Deployment
  defdelegate process_deployment(request_id, subscriptions, garden, opts \\ []), to: Deployment
  defdelegate record_deployment(result), to: Deployment
  defdelegate request_deployment(request), to: Deployment
  defdelegate retry_deployment(deployment, user_id), to: Deployment
  defdelegate update_deployment(deployment, attrs), to: Deployment

  # GardenSeedGeneration delegates
  defdelegate list_garden_seed_generation(garden), to: GardenSeedGeneration
  defdelegate list_garden_seed_generation_profile(garden_id, profile_id), to: GardenSeedGeneration
  defdelegate list_current_seed_generation(garden), to: GardenSeedGeneration
  defdelegate update_garden_seed_generations(report, garden), to: GardenSeedGeneration

  defdelegate upsert_garden_generation(garden_id, profile_id, seed_id, attrs),
    to: GardenSeedGeneration
end
