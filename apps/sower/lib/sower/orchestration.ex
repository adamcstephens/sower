defmodule Sower.Orchestration do
  @moduledoc """
  The Orchestration context.
  """

  import Ecto.Query, warn: false
  alias Sower.Repo

  alias Sower.Orchestration.Agent

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
  Returns the list of subscriptions.

  ## Examples

      iex> list_subscriptions()
      [%Subscription{}, ...]

  """
  def list_subscriptions do
    Repo.all(Subscription)
    |> Sower.Repo.preload(:agent)
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

  @doc """
  Creates a subscription.

  ## Examples

      iex> create_subscription(%{field: value})
      {:ok, %Subscription{}}

      iex> create_subscription(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_subscription(attrs \\ %{}) do
    %Subscription{
      org_id: Sower.Repo.get_org_id()
    }
    |> Subscription.changeset(attrs)
    |> Repo.insert()
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
end
