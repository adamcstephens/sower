defmodule Sower.Orchestration.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:sid, :local_sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "agents" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :name, :string
    field :local_sid, :string
    field :org_id, Ecto.UUID

    has_many :subscriptions, Sower.Orchestration.Subscription
    has_many :deployments, Sower.Orchestration.Deployment

    timestamps()
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :org_id, :local_sid])
    |> validate_required([:name])
  end
end
