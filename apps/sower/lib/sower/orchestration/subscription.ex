defmodule Sower.Orchestration.Subscription do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  alias Sower.Orchestration.{Agent, Deployment, SubscriptionDeployment}

  schema "subscriptions" do
    field :sid, SowerClient.Schemas.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :agent, Agent
    belongs_to :seed, Sower.Seed

    many_to_many :deployments, Deployment, join_through: SubscriptionDeployment

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:agent_id, :seed_id])
    |> validate_required([])
  end
end
