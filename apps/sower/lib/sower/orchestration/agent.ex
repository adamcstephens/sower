defmodule Sower.Orchestration.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:sid, :local_sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "agents" do
    field :sid, Sower.Schema.Sid, autogenerate: true
    field :name, :string
    field :local_sid, :string
    field :org_id, Ecto.UUID

    has_many :subscriptions, Sower.Orchestration.Subscription

    timestamps()
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :org_id, :local_sid])
    |> validate_required([:name])
  end
end
