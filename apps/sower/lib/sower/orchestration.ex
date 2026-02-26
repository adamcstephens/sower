defmodule Sower.Orchestration do
  @moduledoc """
  The Orchestration context.
  """

  alias Sower.Repo
  alias Sower.Orchestration.Agent
  alias Sower.Orchestration.Deployment
  alias Sower.Orchestration.DeploymentPubSub

  import Ecto.Query, warn: false
  import Sower.Authorization

  require Logger

  @doc """
  Returns the list of agents.

  ## Examples

      iex> list_agents()
      [%Agent{}, ...]

  """
  def list_agents do
    Repo.all(Agent)
  end

  @doc """
  Returns the list of agents with their latest deployment preloaded.

  ## Examples

      iex> list_agents_with_latest_deployment()
      [%Agent{latest_deployment: %Deployment{} | nil}, ...]

  """
  def list_agents_with_latest_deployment do
    latest_deployment_query =
      from(d in Deployment,
        where: d.agent_id == parent_as(:agent).id,
        order_by: [desc: d.inserted_at],
        limit: 1
      )

    from(a in Agent,
      as: :agent,
      left_lateral_join: d in subquery(latest_deployment_query),
      on: true,
      select: %{a | latest_deployment: d}
    )
    |> Repo.all()
  end

  def get_agent(
        %SowerClient.AgentHello{agent_sid: nil, name: name, local_sid: local_sid},
        socket
      ) do
    case get_agent_local_sid(local_sid) do
      nil ->
        Logger.debug(
          msg: "Registering new agent",
          name: name,
          local_sid: local_sid
        )

        if socket.assigns.access_token |> can() |> create?(Agent) do
          create_agent(%{name: name, local_sid: local_sid})
        else
          {:error, :unauthorized}
        end

      %Agent{} = agent ->
        Logger.error(
          msg: "Local agent attempted to re-register existing agent",
          name: agent.name,
          local_sid: local_sid,
          existing_agent_sid: agent.sid
        )

        {:error, :unauthorized_agent_hello}
    end
  end

  def get_agent(
        %SowerClient.AgentHello{agent_sid: agent_sid, name: name, local_sid: local_sid},
        socket
      ) do
    case get_agent_sid(agent_sid) do
      nil ->
        Logger.debug(
          msg: "Local agent requested a missing agent",
          name: name,
          local_sid: local_sid,
          requested_agent_sid: agent_sid
        )

        if socket.assigns.access_token |> can() |> create?(Agent) do
          create_agent(%{name: name, local_sid: local_sid})
        else
          {:error, :unauthorized}
        end

      %Agent{local_sid: nil} = agent when agent.name == name ->
        Logger.debug(
          msg: "Registering local sid to existing agent",
          name: agent.name,
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        if socket.assigns.access_token |> can() |> create?(Agent) do
          agent = update_agent(agent, %{local_sid: local_sid})

          {:ok, agent}
        else
          {:error, :unauthorized_agent_hello}
        end

      %Agent{} = agent
      when agent.sid == agent_sid and
             agent.name == name and
             agent.local_sid == local_sid ->
        Logger.debug(
          msg: "Found matching agent",
          name: agent.name,
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        {:ok, agent}

      %Agent{} = agent
      when agent.sid == agent_sid and
             agent.name != name and
             agent.local_sid == local_sid ->
        Logger.info(
          msg: "Found matching agent with different name, renaming",
          name: name,
          previous_name: agent.name,
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        {:ok, agent} = update_agent(agent, %{name: name})

        {:ok, agent}

      %Agent{} = agent ->
        Logger.error(
          msg: "Invalid agent request",
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        {:error, :unauthorized_agent_hello}
    end
  end

  @doc """
  Gets a single agent.

  Raises `Ecto.NoResultsError` if the Agent does not exist.

  ## Examples

      iex> get_agent!(123)
      %Agent{}

      iex> get_agent!(456)
      ** (Ecto.NoResultsError)

  """
  def get_agent!(id), do: Repo.get!(Agent, id)

  @doc """
  Gets a single agent by sid.

  Raises `Ecto.NoResultsError` if the Agent does not exist.

  ## Examples

      iex> get_agent_sid!("123")
      %Agent{}

      iex> get_agent_sid!("456")
      ** (Ecto.NoResultsError)

  """
  def get_agent_sid!(sid), do: Repo.get_by!(Agent, sid: sid)

  @doc """
  Gets a single agent by sid.

  ## Examples

      iex> get_agent_sid!("123")
      %Agent{}

      iex> get_agent_sid!("456")
      nil

  """
  def get_agent_sid(sid), do: Repo.get_by(Agent, sid: sid)

  @doc """
  Gets a single agent by local_sid.

  Raises `Ecto.NoResultsError` if the Agent does not exist.

  ## Examples

      iex> get_agent_local_sid!("123")
      %Agent{}

      iex> get_agent_local_sid!("456")
      nil

  """
  def get_agent_local_sid(local_sid), do: Repo.get_by(Agent, local_sid: local_sid)

  @doc """
  Gets a single agent by local_sid.

  Raises `Ecto.NoResultsError` if the Agent does not exist.

  ## Examples

      iex> get_agent_local_sid!("123")
      %Agent{}

      iex> get_agent_local_sid!("456")
      ** (Ecto.NoResultsError)

  """
  def get_agent_local_sid!(local_sid), do: Repo.get_by!(Agent, local_sid: local_sid)

  @doc """
  Creates a agent.

  ## Examples

      iex> create_agent(%{field: value})
      {:ok, %Agent{}}

      iex> create_agent(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_agent(attrs \\ %{}) do
    %Agent{
      org_id: Sower.Repo.get_org_id(),
      sid: SowerClient.Sid.generate("agent")
    }
    |> Agent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a agent.

  ## Examples

      iex> update_agent(agent, %{field: new_value})
      {:ok, %Agent{}}

      iex> update_agent(agent, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_agent(%Agent{} = agent, attrs) do
    agent
    |> Agent.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a agent.

  ## Examples

      iex> delete_agent(agent)
      {:ok, %Agent{}}

      iex> delete_agent(agent)
      {:error, %Ecto.Changeset{}}

  """
  def delete_agent(%Agent{} = agent) do
    Repo.delete(agent)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking agent changes.

  ## Examples

      iex> change_agent(agent)
      %Ecto.Changeset{data: %Agent{}}

  """
  def change_agent(%Agent{} = agent, attrs \\ %{}) do
    Agent.changeset(agent, attrs)
  end

  alias Sower.Orchestration.Subscription

  @doc """
  List deployments for a specific agent, ordered by most recent first.

  ## Options
    * `:limit` - Maximum number of deployments to return (default: 10)

  ## Examples

      iex> list_deployments(agent, limit: 10)
      [%Deployment{}, ...]
  """
  def list_deployments(%Agent{} = agent, opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    from(d in Deployment,
      where: d.agent_id == ^agent.id,
      order_by: [desc: d.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc """
  Returns the list of subscriptions.

  ## Examples

      iex> list_subscriptions()
      [%Subscription{}, ...]

  """
  def list_subscriptions do
    Repo.all(Subscription)
    |> Sower.Repo.preload([:agent])
  end

  @doc """
  Returns the list of subscriptions for a given agent.
  """
  def list_subscriptions_for_agent(%Agent{} = agent) do
    import Ecto.Query

    Subscription
    |> where([s], s.agent_id == ^agent.id)
    |> Repo.all()
  end

  @doc """
  Gets a single subscription.

  Raises `Ecto.NoResultsError` if the Subscription does not exist.

  ## Examples

      iex> get_subscription!(123)
      %Subscription{}

      iex> get_subscription!(456)
      ** (Ecto.NoResultsError)

  """
  def get_subscription!(id) do
    Repo.get!(Subscription, id)
    |> Sower.Repo.preload(:agent)
  end

  @doc """
  Gets a single subscription by sid.

  Raises `Ecto.NoResultsError` if the Subscription does not exist.

  ## Examples

      iex> get_subscription_sid!(123)
      %Subscription{}

      iex> get_subscription_sid!(456)
      ** (Ecto.NoResultsError)

  """
  def get_subscription_sid!(sid), do: Repo.get_by!(Subscription, sid: sid)

  def get_subscription_sid(sid) do
    Subscription
    |> Repo.get_by(sid: sid)
  end

  @doc """
  Gets a single subscription by sid with deployments preloaded in reverse chronological order.

  Raises `Ecto.NoResultsError` if the Subscription does not exist.

  ## Examples

      iex> get_subscription_sid_with_deployments!("123")
      %Subscription{}

      iex> get_subscription_sid_with_deployments!("456")
      ** (Ecto.NoResultsError)

  """
  def get_subscription_sid_with_deployments!(sid) do
    subscription = get_subscription_sid!(sid)

    Repo.preload(subscription, [
      :agent,
      deployments:
        from(d in Deployment,
          order_by: [
            desc: fragment("? IS NULL", d.deployed_at),
            desc: d.deployed_at,
            desc: d.inserted_at
          ]
        )
    ])
  end

  @doc """
  Gets a single subscription by sid with deployments preloaded in reverse chronological order.

  Returns `nil` if the Subscription does not exist.

  ## Examples

      iex> get_subscription_sid_with_deployments("123")
      %Subscription{}

      iex> get_subscription_sid_with_deployments("456")
      nil

  """
  def get_subscription_sid_with_deployments(sid) do
    get_subscription_sid(sid)
    |> Repo.preload([
      :agent,
      deployments:
        from(d in Deployment,
          order_by: [
            desc: fragment("? IS NULL", d.deployed_at),
            desc: d.deployed_at,
            desc: d.inserted_at
          ]
        )
    ])
  end

  def get_subscription_sids(sids) when is_list(sids) and length(sids) > 0 do
    query = from sub in Subscription, where: sub.sid in ^sids

    Repo.all(query)
  end

  def get_subscription_sids(sids) when is_list(sids) and length(sids) == 0 do
    {:error, :no_sids_provided}
  end

  def find_subscription(%Sower.Seed{} = seed) do
    rules_filter =
      Enum.map(seed.tags || [], fn tag ->
        %{key: tag.key, value: tag.value}
      end)

    from(s in Sower.Orchestration.Subscription,
      where: s.seed_name == ^seed.name,
      where: s.seed_type == ^seed.seed_type,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(?) AS r
            WHERE NOT EXISTS (
              SELECT 1 FROM jsonb_array_elements(?) AS t
              WHERE t->>'key' = r->>'key' AND t->>'value' = r->>'value'
            )
          )
          """,
          s.rules,
          ^rules_filter
        )
    )
    |> Sower.Repo.all()
  end

  @doc """
  Creates a subscription.

  ## Examples

      iex> create_subscription(%{field: value})
      {:ok, %Subscription{}}

      iex> create_subscription(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_subscription(attrs \\ %{}) do
    case %Subscription{
           org_id: Sower.Repo.get_org_id(),
           sid: SowerClient.Sid.generate("sub")
         }
         |> Subscription.changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace, [:updated_at, :rules]},
           conflict_target: [:agent_id, :org_id, :seed_name, :seed_type],
           returning: true
         ) do
      {:ok, sub} -> {:ok, Repo.reload(sub)}
      err -> err
    end
  end

  @doc """
  Register a subscription from a SowerClient.Orchestration.Subscription struct.

  ## Examples

      iex> register_subscription(req, agent_id)
      {:ok, %SowerClient.Orchestration.Subscription{}}

      iex> register_subscription(req, agent_id)
      {:error, %Ecto.Changeset{}}

  """
  def register_subscription(
        %SowerClient.Orchestration.Subscription{
          seed_name: seed_name,
          seed_type: seed_type,
          rules: rules
        },
        agent_id
      ) do
    case create_subscription(%{
           agent_id: agent_id,
           seed_name: seed_name,
           seed_type: seed_type,
           rules: rules
         }) do
      {:ok, subscription} ->
        {:ok, SowerClient.Orchestration.Subscription.cast!(subscription)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Sync subscriptions for an agent. Upserts all provided subscriptions
  and deletes any existing subscriptions not in the list.
  """
  def sync_subscriptions(subscriptions, agent_id) do
    Repo.transaction(fn ->
      registered =
        Enum.map(subscriptions, fn sub ->
          case register_subscription(sub, agent_id) do
            {:ok, s} -> s
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      registered_sids = Enum.map(registered, & &1.sid)

      from(s in Subscription,
        where: s.agent_id == ^agent_id,
        where: s.sid not in ^registered_sids
      )
      |> Repo.delete_all()

      registered
    end)
  end

  @doc """
  Updates a subscription.

  ## Examples

      iex> update_subscription(subscription, %{field: new_value})
      {:ok, %Subscription{}}

      iex> update_subscription(subscription, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_subscription(%Subscription{} = subscription, attrs) do
    subscription
    |> Subscription.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a subscription.

  ## Examples

      iex> delete_subscription(subscription)
      {:ok, %Subscription{}}

      iex> delete_subscription(subscription)
      {:error, %Ecto.Changeset{}}

  """
  def delete_subscription(%Subscription{} = subscription) do
    Repo.delete(subscription)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking subscription changes.

  ## Examples

      iex> change_subscription(subscription)
      %Ecto.Changeset{data: %Subscription{}}

  """
  def change_subscription(%Subscription{} = subscription, attrs \\ %{}) do
    subscription
    |> Repo.preload(:agent)
    |> Subscription.changeset(attrs)
  end

  alias Sower.Seed

  def match_seed(%Subscription{} = subscription) do
    tags =
      Enum.map(subscription.rules || [], fn rule ->
        %{key: rule.key, value: rule.value}
      end)

    Seed.latest(subscription.seed_name, subscription.seed_type, tags)
  end

  def list_matching_seeds(%Subscription{} = subscription, limit \\ 10) do
    tags =
      Enum.map(subscription.rules || [], fn rule ->
        %{key: rule.key, value: rule.value}
      end)

    Seed.list_matching(subscription.seed_name, subscription.seed_type, tags, limit: limit)
  end

  @doc """
  Returns the list of deployments.

  ## Examples

      iex> list_deployments()
      [%Deployment{}, ...]

  """
  def list_deployments do
    query =
      from r in Deployment,
        order_by: [
          desc: fragment("? IS NULL", r.deployed_at),
          desc: r.deployed_at,
          desc: r.inserted_at
        ]

    Repo.all(query)
  end

  @doc """
  Gets a single deployment.

  Raises `Ecto.NoResultsError` if the Deployment does not exist.

  ## Examples

      iex> get_deployment!(123)
      %Deployment{}

      iex> get_deployment!(456)
      ** (Ecto.NoResultsError)

  """
  def get_deployment!(id), do: Repo.get!(Deployment, id)

  def get_deployment_sid!(sid) do
    Deployment
    |> Repo.get_by!(sid: sid)
  end

  def get_deployment_sid(sid) do
    Deployment
    |> Repo.get_by(sid: sid)
  end

  @doc """
  Creates a deployment.

  ## Examples

      iex> create_deployment(%{field: value})
      {:ok, %Deployment{}}

      iex> create_deployment(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_deployment(attrs \\ %{}) do
    result =
      %Deployment{
        org_id: Sower.Repo.get_org_id(),
        sid: SowerClient.Sid.generate("deploy")
      }
      |> Deployment.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, deployment} ->
        DeploymentPubSub.broadcast_deployment_change(deployment, :created)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Updates a deployment.

  ## Examples

      iex> update_deployment(deployment, %{field: new_value})
      {:ok, %Deployment{}}

      iex> update_deployment(deployment, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_deployment(%Deployment{} = deployment, attrs) do
    result =
      deployment
      |> Repo.preload([:seeds, :subscriptions])
      |> Deployment.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_deployment} ->
        DeploymentPubSub.broadcast_deployment_change(updated_deployment, :updated)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Deletes a deployment.

  ## Examples

      iex> delete_deployment(deployment)
      {:ok, %Deployment{}}

      iex> delete_deployment(deployment)
      {:error, %Ecto.Changeset{}}

  """
  def delete_deployment(%Deployment{} = deployment) do
    Repo.delete(deployment)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking deployment changes.

  ## Examples

      iex> change_deployment(deployment)
      %Ecto.Changeset{data: %Deployment{}}

  """
  def change_deployment(%Deployment{} = deployment, attrs \\ %{}) do
    Deployment.changeset(deployment, attrs)
  end

  # Deployment Request Handling
  #
  # Entry points for deployment requests with different behaviors:
  #
  # - handle_deployment_request/2: Main entry point from agent channel
  #   Flow: validate request → validate subscriptions → spawn async task
  #   Task: match seeds → create deployment → broadcast to agent
  #
  # - request_deployment/2: Synchronous deployment (no broadcast)
  #   Used for internal synchronous requests without async behavior
  #
  # - deploy_subscription/1: Deploy a single subscription
  #   Matches subscription against available seeds, used by other functions

  @doc """
  Initiates an async deployment for a single subscription.

  Looks up the subscription's agent, matches seeds, and spawns async task
  to create deployment and broadcast results back to agent.

  Returns {:ok, request_id} if async task starts successfully,
  {:error, reason} otherwise.

  ## Examples

      iex> deploy_subscription(subscription)
      {:ok, "request_abc123"}

      iex> deploy_subscription(subscription_with_no_agent)
      {:error, :agent_not_found}

  """
  def deploy_subscription(%Subscription{} = sub, opts \\ []) do
    subscription = Repo.preload(sub, :agent)

    case subscription.agent do
      nil ->
        {:error, :agent_not_found}

      %Agent{} = agent ->
        request_id = SowerClient.Sid.generate("request")
        process_deployment(request_id, [subscription], agent, opts)
    end
  end

  @doc """
  Request and create a deployment for subscriptions (synchronous, no broadcast).

  Used internally for synchronous deployment requests without async broadcast.
  Validates subscriptions exist and match, then creates deployment record.

  Returns the structured Deployment response.

  ## Examples

      iex> request_deployment(deployment_request)
      {:ok, %SowerClient.Orchestration.Deployment{}}

      iex> request_deployment(invalid_request)
      {:error, :subscription_not_found}

  """
  def request_deployment(%SowerClient.Orchestration.DeploymentRequest{} = request) do
    with {:ok, subs} <- validate_request_subscriptions(request.subscription_sids) do
      do_deployment(request.request_id, subs, force: request.force)
    else
      {:error, _} = err ->
        Logger.error(msg: "Failed to process deployment request", error: IO.inspect(err))
        {:error, :unknown_error}
    end
  end

  defp validate_request_subscriptions(sids) when is_list(sids) and length(sids) > 0 do
    subs = get_subscription_sids(sids)
    subs = Repo.preload(subs, :agent)

    if subs == [] do
      {:error, :subscription_not_found}
    else
      {:ok, subs}
    end
  end

  defp validate_request_subscriptions(_), do: {:error, :subscription_not_found}

  @doc """
  Handle a deployment request from an agent channel.

  Validates the deployment request and subscriptions synchronously,
  then delegates to process_deployment/3 for async processing and broadcasting.

  Returns {:ok, request_id} on successful validation, {:error, reason} otherwise.
  """
  def handle_deployment_request(payload, agent) do
    with {:ok, request} <- SowerClient.Orchestration.DeploymentRequest.cast(payload),
         {:ok, subscriptions} <- validate_deployment_request(request, agent.id) do
      process_deployment(request.request_id, subscriptions, agent, force: request.force)
    end
  end

  defp validate_deployment_request(
         %SowerClient.Orchestration.DeploymentRequest{} = request,
         agent_id
       ) do
    subs = get_subscription_sids(request.subscription_sids)

    cond do
      subs == [] ->
        {:error, :subscription_not_found}

      not Enum.all?(subs, &(&1.agent_id == agent_id)) ->
        {:error, :unauthorized}

      true ->
        {:ok, Repo.preload(subs, :agent)}
    end
  end

  @doc """
  Process a deployment request asynchronously.

  Spawns an async task to match seeds, create deployment record, and broadcast
  results back to agent via channel. Validation happens synchronously before
  task spawn.

  Returns {:ok, request_id} if async task starts successfully,
  {:error, reason} if validation fails.

  ## Examples

      iex> process_deployment(request_id, subscriptions, agent)
      {:ok, "request_123"}

  """
  def process_deployment(request_id, subscriptions, %Agent{} = agent, opts \\ []) do
    Task.Supervisor.start_child(Sower.TaskSupervisor, fn ->
      Repo.put_org_id(agent.org_id)

      case do_deployment(request_id, subscriptions, opts) do
        {:ok, deployment} ->
          SowerWeb.Endpoint.broadcast(
            "agent:#{agent.sid}",
            "deployment",
            Map.from_struct(deployment)
          )

        {:error, reason} ->
          SowerWeb.Endpoint.broadcast(
            "agent:#{agent.sid}",
            "deployment:error",
            %{request_id: request_id, reason: to_string(reason)}
          )
      end
    end)

    {:ok, request_id}
  end

  defp do_deployment(request_id, subscriptions, opts) do
    force? = Keyword.get(opts, :force, false)
    agent_id = hd(subscriptions).agent_id

    seed_deploys =
      subscriptions
      |> Enum.reduce([], fn sub, acc ->
        case match_seed(sub) do
          nil ->
            acc

          seed ->
            [
              %SowerClient.Orchestration.SeedDeployment{
                seed: seed,
                subscription_sid: sub.sid
              }
              | acc
            ]
        end
      end)

    seeds = Enum.map(seed_deploys, & &1.seed)

    if seeds == [] do
      {:error, :seeds_not_found}
    else
      content_hash = compute_content_hash(seeds)

      case find_duplicate_deployment(agent_id, content_hash, force?) do
        {:skip, existing} ->
          existing = Repo.preload(existing, [:seeds])

          {:ok,
           %SowerClient.Orchestration.Deployment{
             request_id: request_id,
             sid: existing.sid,
             seed_deployments: seed_deploys,
             skipped: true
           }}

        :proceed ->
          case create_deployment(%{
                 agent_id: agent_id,
                 content_hash: content_hash,
                 seeds: seeds,
                 subscriptions: subscriptions
               }) do
            {:ok, deploy} ->
              {:ok,
               %SowerClient.Orchestration.Deployment{
                 request_id: request_id,
                 sid: deploy.sid,
                 seed_deployments: seed_deploys,
                 skipped: false
               }}

            other ->
              other
          end
      end
    end
  end

  defp compute_content_hash(seeds) do
    seeds
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp find_duplicate_deployment(_agent_id, _content_hash, true), do: :proceed

  defp find_duplicate_deployment(agent_id, content_hash, false) do
    query =
      from(d in Deployment,
        where:
          d.agent_id == ^agent_id and
            d.content_hash == ^content_hash and
            (d.result == :success or is_nil(d.result)),
        order_by: [desc: d.inserted_at],
        limit: 1
      )

    case Repo.one(query) do
      nil -> :proceed
      deployment -> {:skip, deployment}
    end
  end

  def record_deployment(%SowerClient.Orchestration.DeploymentResult{} = result) do
    case get_deployment_sid(result.deployment_sid) do
      nil ->
        {:error, :deployment_not_found}

      deploy ->
        update_deployment(deploy, %{deployed_at: result.deployed_at, result: result.result})
    end
  end

  alias Sower.Orchestration.{NixProfile, AgentSeedGeneration}

  @doc """
  Lists all agent_seed_generations for an agent, ordered by generation_number descending.
  Preloads seed and profile associations.
  """
  def list_agent_seed_generation(%Agent{id: agent_id}) do
    from(asg in AgentSeedGeneration,
      where: asg.agent_id == ^agent_id,
      order_by: [desc: asg.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  @doc """
  Lists only the current (active) generations for an agent.
  Preloads seed and profile associations.
  """
  def list_current_seed_generation(%Agent{id: agent_id}) do
    from(asg in AgentSeedGeneration,
      where: asg.agent_id == ^agent_id and asg.is_current == true,
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  @doc """
  Lists all generations for a specific agent and profile.
  Ordered by generation_number descending.
  """
  def list_agent_seed_generation_profile(agent_id, profile_id) do
    from(asg in AgentSeedGeneration,
      where: asg.agent_id == ^agent_id and asg.profile_id == ^profile_id,
      order_by: [desc: asg.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  @doc """
  Upserts an agent_seed_generation from report data.
  Uses lookup semantics on (agent_id, seed_id), inserting missing rows and
  updating existing rows.

  ## Parameters
    - agent_id: The agent's ID
    - profile_id: The nix_profile's ID
    - seed_id: The seed's ID
    - attrs: Map with :generation_number, :is_current, :created_at_generation
  """
  def upsert_agent_generation(agent_id, profile_id, seed_id, attrs) do
    now = DateTime.utc_now()

    changeset_attrs = %{
      org_id: Repo.get_org_id(),
      agent_id: agent_id,
      seed_id: seed_id,
      profile_id: profile_id,
      generation_number: attrs.generation_number,
      is_current: attrs.is_current,
      created_at_generation: attrs.created_at_generation
    }

    case Repo.get_by(AgentSeedGeneration, agent_id: agent_id, seed_id: seed_id) do
      nil ->
        %AgentSeedGeneration{}
        |> AgentSeedGeneration.changeset(changeset_attrs)
        |> Repo.insert()

      %AgentSeedGeneration{} = existing ->
        update_attrs = %{
          profile_id: profile_id,
          generation_number: attrs.generation_number,
          is_current: attrs.is_current,
          created_at_generation: attrs.created_at_generation,
          updated_at: now
        }

        if generation_row_changed?(existing, update_attrs) do
          existing
          |> AgentSeedGeneration.changeset(update_attrs)
          |> Repo.update()
        else
          {:ok, existing}
        end
    end
  end

  @doc """
  Updates agent_seed_generations from an agent's seeds report.

  For each profile in the report:
  - Finds or creates the nix_profile by path
  - For each generation, looks up the seed by artifact (store path)
  - Upserts agent_seed_generation records for found seeds
  - Deletes agent_seed_generations for seeds no longer reported by the agent

  Unknown artifacts are automatically registered as seeds with `agent_source` tag.
  """
  def update_agent_seed_generations(
        %SowerClient.Orchestration.AgentSeedsReport{} = report,
        %Agent{} = agent
      ) do
    Repo.transaction(fn ->
      if Enum.empty?(report.profiles) do
        # Empty report means agent has no subscriptions - delete all generations
        delete_all_agent_seed_generations(agent.id)
      else
        for profile <- report.profiles do
          nix_profile = NixProfile.find_or_create!(profile.profile_path)
          rows = resolve_profile_generation_rows(agent, profile)
          sync_profile_generation_rows(agent, nix_profile, rows)
        end
      end

      :ok
    end)
  end

  defp resolve_profile_generation_rows(%Agent{} = agent, profile) do
    artifacts =
      profile.generations
      |> Enum.map(& &1.path)
      |> Enum.uniq()

    seeds_by_artifact =
      from(s in Seed, where: s.artifact in ^artifacts)
      |> Repo.all()
      |> Map.new(&{&1.artifact, &1})

    {rows, _seeds_by_artifact} =
      Enum.reduce(profile.generations, {[], seeds_by_artifact}, fn gen, {rows, seeds} ->
        {seed, seeds} =
          case Map.get(seeds, gen.path) do
            nil ->
              case Seed.find_or_register(agent, gen, profile) do
                {:ok, seed} ->
                  {seed, Map.put(seeds, gen.path, seed)}

                {:error, error} ->
                  Logger.warning(
                    msg: "Failed to auto-register seed from agent",
                    artifact: gen.path,
                    error: error
                  )

                  {nil, seeds}
              end

            seed ->
              {seed, seeds}
          end

        case {seed, parse_generation_created(gen.created)} do
          {nil, _} ->
            {rows, seeds}

          {_, :error} ->
            Logger.warning(
              msg: "Failed to parse generation created timestamp",
              artifact: gen.path,
              created: gen.created
            )

            {rows, seeds}

          {%Seed{id: seed_id}, {:ok, created_at}} ->
            row = %{
              seed_id: seed_id,
              generation_number: gen.generation_number,
              is_current: gen.is_current,
              created_at_generation: created_at
            }

            {[row | rows], seeds}
        end
      end)

    rows
    |> Enum.reverse()
    |> normalize_current_generation_rows()
    |> Enum.reverse()
    |> Enum.uniq_by(& &1.seed_id)
    |> Enum.reverse()
  end

  defp parse_generation_created(%DateTime{} = dt), do: {:ok, DateTime.truncate(dt, :second)}

  defp parse_generation_created(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, DateTime.truncate(dt, :second)}
      _ -> :error
    end
  end

  defp parse_generation_created(_), do: :error

  defp normalize_current_generation_rows(rows) do
    current_seed_id =
      Enum.reduce(rows, nil, fn row, acc -> if row.is_current, do: row.seed_id, else: acc end)

    if is_nil(current_seed_id) do
      rows
    else
      Enum.map(rows, fn row ->
        %{row | is_current: row.seed_id == current_seed_id}
      end)
    end
  end

  defp sync_profile_generation_rows(%Agent{} = agent, nix_profile, rows) do
    if Enum.any?(rows, & &1.is_current) do
      from(asg in AgentSeedGeneration,
        where: asg.agent_id == ^agent.id and asg.profile_id == ^nix_profile.id
      )
      |> Repo.update_all(set: [is_current: false])
    end

    keep_seed_ids =
      Enum.reduce(rows, [], fn row, acc ->
        upsert_agent_generation(agent.id, nix_profile.id, row.seed_id, row)
        [row.seed_id | acc]
      end)
      |> Enum.uniq()

    delete_stale_agent_seed_generations(agent.id, nix_profile.id, keep_seed_ids)
  end

  defp generation_row_changed?(existing, attrs) do
    existing.profile_id != attrs.profile_id or
      existing.generation_number != attrs.generation_number or
      existing.is_current != attrs.is_current or
      existing.created_at_generation != attrs.created_at_generation
  end

  defp delete_stale_agent_seed_generations(agent_id, profile_id, keep_seed_ids) do
    query =
      from(asg in AgentSeedGeneration,
        where: asg.agent_id == ^agent_id and asg.profile_id == ^profile_id
      )

    query =
      if keep_seed_ids == [] do
        query
      else
        from(asg in query, where: asg.seed_id not in ^keep_seed_ids)
      end

    Repo.delete_all(query)
  end

  defp delete_all_agent_seed_generations(agent_id) do
    from(asg in AgentSeedGeneration, where: asg.agent_id == ^agent_id)
    |> Repo.delete_all()
  end
end
