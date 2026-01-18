defmodule Sower.Orchestration.AgentSeedProfile do
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Sower.Repo
  alias Sower.Orchestration.{Agent, NixProfile}

  schema "agent_seed_profiles" do
    field :org_id, Ecto.UUID

    belongs_to :agent, Agent
    belongs_to :seed, Sower.Seed
    belongs_to :profile, NixProfile

    field :generation_number, :integer
    field :is_current, :boolean, default: false
    field :created_at_generation, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(%__MODULE__{} = agent_seed_profile, attrs) do
    agent_seed_profile
    |> cast(attrs, [
      :org_id,
      :agent_id,
      :seed_id,
      :profile_id,
      :generation_number,
      :is_current,
      :created_at_generation
    ])
    |> validate_required([:org_id, :agent_id, :seed_id, :profile_id, :created_at_generation])
    |> foreign_key_constraint(:org_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:seed_id)
    |> foreign_key_constraint(:profile_id)
    |> unique_constraint([:agent_id, :seed_id])
  end

  @doc """
  Lists all agent_seed_profiles for an agent, ordered by generation_number descending.
  Preloads seed and profile associations.
  """
  def list_for_agent(agent_id) do
    from(asp in __MODULE__,
      where: asp.agent_id == ^agent_id,
      order_by: [desc: asp.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  @doc """
  Lists only the current (active) generations for an agent.
  Preloads seed and profile associations.
  """
  def list_current_for_agent(agent_id) do
    from(asp in __MODULE__,
      where: asp.agent_id == ^agent_id and asp.is_current == true,
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  @doc """
  Lists all generations for a specific agent and profile.
  Ordered by generation_number descending.
  """
  def list_for_agent_profile(agent_id, profile_id) do
    from(asp in __MODULE__,
      where: asp.agent_id == ^agent_id and asp.profile_id == ^profile_id,
      order_by: [desc: asp.generation_number],
      preload: [:seed, :profile]
    )
    |> Repo.all()
  end

  @doc """
  Upserts an agent_seed_profile from report data.
  Uses the unique constraint on (agent_id, seed_id) for conflict resolution.

  ## Parameters
    - agent_id: The agent's ID
    - profile_id: The nix_profile's ID
    - seed_id: The seed's ID
    - attrs: Map with :generation_number, :is_current, :created_at_generation
  """
  def upsert_from_report(agent_id, profile_id, seed_id, attrs) do
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

    %__MODULE__{}
    |> changeset(changeset_attrs)
    |> Repo.insert(
      on_conflict: [
        set: [
          profile_id: profile_id,
          generation_number: attrs.generation_number,
          is_current: attrs.is_current,
          updated_at: now
        ]
      ],
      conflict_target: [:agent_id, :seed_id]
    )
  end
end
