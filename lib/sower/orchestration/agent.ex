defmodule Sower.Orchestration.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:sid, :remote_sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "agents" do
    field :sid, Sower.Schema.Sid, autogenerate: true
    field :name, :string
    field :remote_sid, :string
    field :org_id, Ecto.UUID

    timestamps()
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end
end
