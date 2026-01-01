defmodule Sower.Orchestration do
  @moduledoc """
  The Orchestration context.
  """

  alias Sower.Repo
  alias Sower.Orchestration.Agent

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
      org_id: Sower.Repo.get_org_id()
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
  Find deployments for an agent
  """
  def deployments_for_agent(%Agent{} = agent) do
    agent.subscriptions
    |> Enum.map(& &1.deployments)
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
    # TODO handle changing rules
    case %Subscription{org_id: Sower.Repo.get_org_id()}
         |> Subscription.changeset(attrs)
         |> Repo.insert(
           on_conflict: {:replace, [:updated_at]},
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

  def match_seed(%Subscription{rules: rules} = subscription) do
    # Build subquery to find all matching seed IDs
    base_query =
      from s in Seed,
        where: s.name == ^subscription.seed_name and s.seed_type == ^subscription.seed_type,
        select: s.id

    matching_seed_ids =
      Enum.reduce(rules || [], base_query, fn rule, q ->
        op =
          case rule.op do
            op when is_atom(op) -> op
            op when is_binary(op) -> String.to_existing_atom(op)
          end

        case op do
          :eq ->
            from s in q,
              join: t in assoc(s, :tags),
              where: t.key == ^rule.key and t.value == ^rule.value
        end
      end)
      |> distinct(true)
      |> Repo.all()

    # Now find the latest seed from the matching IDs
    case matching_seed_ids do
      [] ->
        nil

      ids ->
        from(s in Seed,
          where: s.id in ^ids,
          order_by: [desc: s.inserted_at, desc: s.id],
          limit: 1
        )
        |> Repo.one()
        |> Repo.preload(:tags)
    end
  end

  @doc """
  Returns the list of deployments.

  ## Examples

      iex> list_deployments()
      [%Deployment{}, ...]

  """
  def list_deployments do
    query = from r in Deployment, order_by: [desc: r.deployed_at]
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
    %Deployment{
      org_id: Sower.Repo.get_org_id()
    }
    |> Deployment.changeset(attrs)
    |> Repo.insert()
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
    deployment
    |> Repo.preload([:seeds, :subscriptions])
    |> Deployment.changeset(attrs)
    |> Repo.update()
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
         seeds <-
           subs |> Enum.map(&match_seed/1),
         {:ok, deploy} <-
           create_deployment(%{
             seeds: seeds,
             subscriptions: subs
           }) do
      {:ok,
       %SowerClient.Orchestration.Deployment{
         request_id: request.request_id,
         subscription_sids: Enum.map(subs, & &1.sid),
         sid: deploy.sid,
         seeds: seeds
       }}
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
end
