defmodule Sower.Orchestration.Agent do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, warn: false
  import Sower.Authorization

  alias Sower.Repo
  alias Sower.Orchestration.Deployment

  require Logger

  @derive {Jason.Encoder, only: [:sid, :local_sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "agents" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :name, :string
    field :local_sid, :string
    field :org_id, Ecto.UUID

    has_many :subscriptions, Sower.Orchestration.Subscription
    has_many :deployments, Sower.Orchestration.Deployment
    has_many :agent_seed_generations, Sower.Orchestration.AgentSeedGeneration

    field :latest_deployment, :any, virtual: true

    timestamps()
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :org_id, :local_sid])
    |> validate_required([:name])
  end

  def list_agents do
    Repo.all(__MODULE__)
  end

  def list_agents_with_latest_deployment do
    latest_deployment_query =
      from(d in Deployment,
        where: d.agent_id == parent_as(:agent).id,
        order_by: [desc: d.inserted_at],
        limit: 1
      )

    from(a in __MODULE__,
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

        if socket.assigns.access_token |> can() |> create?(__MODULE__) do
          create_agent(%{name: name, local_sid: local_sid})
        else
          {:error, :unauthorized}
        end

      %__MODULE__{} = agent ->
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

        if socket.assigns.access_token |> can() |> create?(__MODULE__) do
          create_agent(%{name: name, local_sid: local_sid})
        else
          {:error, :unauthorized}
        end

      %__MODULE__{local_sid: nil} = agent when agent.name == name ->
        Logger.debug(
          msg: "Registering local sid to existing agent",
          name: agent.name,
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        if socket.assigns.access_token |> can() |> create?(__MODULE__) do
          agent = update_agent(agent, %{local_sid: local_sid})

          {:ok, agent}
        else
          {:error, :unauthorized_agent_hello}
        end

      %__MODULE__{} = agent
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

      %__MODULE__{} = agent
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

      %__MODULE__{} = agent ->
        Logger.error(
          msg: "Invalid agent request",
          local_sid: local_sid,
          agent_sid: agent.sid
        )

        {:error, :unauthorized_agent_hello}
    end
  end

  def get_agent!(id), do: Repo.get!(__MODULE__, id)

  def get_agent_sid!(sid), do: Repo.get_by!(__MODULE__, sid: sid)

  def get_agent_sid(sid), do: Repo.get_by(__MODULE__, sid: sid)

  def get_agent_local_sid(local_sid), do: Repo.get_by(__MODULE__, local_sid: local_sid)

  def get_agent_local_sid!(local_sid), do: Repo.get_by!(__MODULE__, local_sid: local_sid)

  def create_agent(attrs \\ %{}) do
    %__MODULE__{
      org_id: Sower.Repo.get_org_id(),
      sid: SowerClient.Sid.generate("agent")
    }
    |> changeset(attrs)
    |> Repo.insert()
  end

  def update_agent(%__MODULE__{} = agent, attrs) do
    agent
    |> changeset(attrs)
    |> Repo.update()
  end

  def delete_agent(%__MODULE__{} = agent) do
    Repo.delete(agent)
  end

  def change_agent(%__MODULE__{} = agent, attrs \\ %{}) do
    changeset(agent, attrs)
  end
end
