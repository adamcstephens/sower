defmodule Sower.Orchestration.AgentSeedGeneration do
  use Sower.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Sower.Repo
  alias Sower.Orchestration.{Agent, NixProfile}

  schema "agent_seed_generations" do
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
  def changeset(%__MODULE__{} = agent_seed_generation, attrs) do
    agent_seed_generation
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
end
