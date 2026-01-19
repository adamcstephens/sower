defmodule Sower.Orchestration do
  @moduledoc """
  The Orchestration context.
  """

  alias Sower.Repo
  alias Sower.Orchestration.Agent
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
  alias Sower.Orchestration.Deployment

  @doc """
  List deployments for a specific agent, ordered by most recent first.

  ## Options
    * `:limit` - Maximum number of deployments to return (default: 10)

  ## Examples

      iex> list_deployments_for_agent(agent, limit: 10)
      [%Deployment{}, ...]
  """
  def list_deployments_for_agent(%Agent{} = agent, opts \\ []) do
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

  alias Sower.Orchestration.Deployment
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

  @doc """
  Request and create a deployment for a subscription
  """
  def request_deployment(%SowerClient.Orchestration.DeploymentRequest{} = request) do
    with subs when subs != [] <- get_subscription_sids(request.subscription_sids),
         subs <- Repo.preload(subs, :agent),
         agent_id <- hd(subs).agent_id,
         seeds <-
           subs |> Enum.map(&match_seed/1) |> Enum.reject(&is_nil/1) do
      if seeds == [] do
        {:error, :seeds_not_found}
      else
        case create_deployment(%{
               agent_id: agent_id,
               seeds: seeds,
               subscriptions: subs
             }) do
          {:ok, deploy} ->
            {:ok,
             %SowerClient.Orchestration.Deployment{
               request_id: request.request_id,
               subscription_sids: Enum.map(subs, & &1.sid),
               sid: deploy.sid,
               seeds: seeds
             }}

          other ->
            other
        end
      end
    else
      {:error, _} = err ->
        Logger.error(msg: "Failed to return deployment", error: IO.inspect(err))
        {:error, :unknown_error}

      nil ->
        {:error, :subscription_not_found}
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
      for profile <- report.profiles do
        nix_profile = NixProfile.find_or_create!(profile.profile_path)

        # Collect seed_ids we're upserting for this profile
        upserted_seed_ids =
          for gen <- profile.generations, reduce: [] do
            acc ->
              case Seed.find_or_register_from_agent(agent, gen, profile) do
                {:ok, seed} ->
                  upsert_agent_seed_generation(agent, nix_profile, seed, gen)
                  [seed.id | acc]

                {:error, error} ->
                  Logger.warning(
                    msg: "Failed to auto-register seed from agent",
                    artifact: gen.path,
                    error: error
                  )

                  acc
              end
          end

        # Delete agent_seed_generations for this profile that are no longer in the report
        delete_stale_agent_seed_generations(agent.id, nix_profile.id, upserted_seed_ids)
      end

      :ok
    end)
  end

  defp upsert_agent_seed_generation(%Agent{} = agent, nix_profile, seed, gen) do
    # If this generation is_current, clear other is_current flags first
    if gen.is_current do
      from(asg in AgentSeedGeneration,
        where: asg.agent_id == ^agent.id and asg.profile_id == ^nix_profile.id
      )
      |> Repo.update_all(set: [is_current: false])
    end

    # Parse created timestamp
    created_at =
      case gen.created do
        %DateTime{} = dt -> dt
        str when is_binary(str) -> DateTime.from_iso8601(str) |> elem(1)
      end

    AgentSeedGeneration.upsert_from_report(agent.id, nix_profile.id, seed.id, %{
      generation_number: gen.generation_number,
      is_current: gen.is_current,
      created_at_generation: created_at
    })
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
end
