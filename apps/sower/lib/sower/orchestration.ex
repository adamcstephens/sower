defmodule Sower.Orchestration do
  @moduledoc """
  The Orchestration context.
  """

  alias Sower.Orchestration.Agent
  alias Sower.Orchestration.Deployment
  alias Sower.Orchestration.Subscription
  alias Sower.Orchestration.AgentSeedGeneration

  # Agent delegates
  defdelegate list_agents(), to: Agent
  defdelegate list_agents_with_latest_deployment(), to: Agent
  defdelegate get_agent(hello, socket), to: Agent
  defdelegate get_agent!(id), to: Agent
  defdelegate get_agent_sid!(sid), to: Agent
  defdelegate get_agent_sid(sid), to: Agent
  defdelegate get_agent_local_sid(local_sid), to: Agent
  defdelegate get_agent_local_sid!(local_sid), to: Agent
  defdelegate create_agent(attrs \\ %{}), to: Agent
  defdelegate update_agent(agent, attrs), to: Agent
  defdelegate delete_agent(agent), to: Agent
  defdelegate change_agent(agent, attrs \\ %{}), to: Agent

  # Subscription delegates
  defdelegate list_subscriptions(), to: Subscription
  defdelegate list_subscriptions_for_agent(agent), to: Subscription
  defdelegate get_subscription!(id), to: Subscription
  defdelegate get_subscription_sid!(sid), to: Subscription
  defdelegate get_subscription_sid(sid), to: Subscription
  defdelegate get_subscription_sid_with_deployments!(sid), to: Subscription
  defdelegate get_subscription_sid_with_deployments(sid), to: Subscription
  defdelegate get_subscription_sids(sids), to: Subscription
  defdelegate find_subscription(seed), to: Subscription
  defdelegate create_subscription(attrs \\ %{}), to: Subscription
  defdelegate register_subscription(req, agent_id), to: Subscription
  defdelegate sync_subscriptions(subscriptions, agent_id), to: Subscription
  defdelegate update_subscription(subscription, attrs), to: Subscription
  defdelegate delete_subscription(subscription), to: Subscription
  defdelegate change_subscription(subscription, attrs \\ %{}), to: Subscription

  # Deployment delegates
  defdelegate list_deployments(), to: Deployment
  defdelegate list_deployments(agent, opts \\ []), to: Deployment
  defdelegate list_unresolved_deployments_for_agent(agent, opts \\ []), to: Deployment
  defdelegate get_deployment!(id), to: Deployment
  defdelegate get_deployment_sid!(sid), to: Deployment
  defdelegate get_deployment_sid(sid), to: Deployment
  defdelegate create_deployment(attrs \\ %{}), to: Deployment
  defdelegate update_deployment(deployment, attrs), to: Deployment
  defdelegate delete_deployment(deployment), to: Deployment
  defdelegate change_deployment(deployment, attrs \\ %{}), to: Deployment
  defdelegate retry_deployment(deployment, user_id), to: Deployment
  defdelegate replay_unresolved_deployments(agent, opts \\ []), to: Deployment
  defdelegate match_seed(subscription), to: Deployment
  defdelegate list_matching_seeds(subscription, limit \\ 10), to: Deployment
  defdelegate deploy_subscription(subscription, opts \\ []), to: Deployment
  defdelegate request_deployment(request), to: Deployment
  defdelegate handle_deployment_request(payload, agent), to: Deployment
  defdelegate process_deployment(request_id, subscriptions, agent, opts \\ []), to: Deployment
  defdelegate record_deployment(result), to: Deployment
  defdelegate finalize_stale_deployments(opts \\ []), to: Deployment

  # AgentSeedGeneration delegates
  defdelegate list_agent_seed_generation(agent), to: AgentSeedGeneration
  defdelegate list_current_seed_generation(agent), to: AgentSeedGeneration
  defdelegate list_agent_seed_generation_profile(agent_id, profile_id), to: AgentSeedGeneration

  defdelegate upsert_agent_generation(agent_id, profile_id, seed_id, attrs),
    to: AgentSeedGeneration

  defdelegate update_agent_seed_generations(report, agent), to: AgentSeedGeneration
end
