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

    many_to_many :deployments, Deployment, join_through: SubscriptionDeployment

    field :seed_name, :string
    field :seed_type, :string
    embeds_many :rules, __MODULE__.Rule

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:agent_id, :seed_name, :seed_type])
    |> unique_constraint([:agent_id, :org_id])
  end

  defmodule Rule do
    use Ecto.Schema

    embedded_schema do
      field :key, :string
      field :op, Ecto.Enum, values: [:eq]
      field :value, :string
    end
  end
end
