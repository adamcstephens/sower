defmodule Sower.Orchestration.Deployment do
  use Sower.Schema
  import Ecto.Changeset

  alias Sower.Orchestration

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "deployments" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :agent, Sower.Orchestration.Agent
    belongs_to :parent_deployment, __MODULE__
    has_many :retries, __MODULE__, foreign_key: :parent_deployment_id
    belongs_to :retried_by_user, Sower.Accounts.User

    many_to_many :subscriptions, Sower.Orchestration.Subscription,
      join_through: Orchestration.SubscriptionDeployment

    many_to_many :seeds, Sower.Seed, join_through: Orchestration.SeedDeployment

    field :deployed_at, :utc_datetime
    field :result, Ecto.Enum, values: [:success, :failure, :partial]
    field :content_hash, :string
    field :retry_ordinal, :integer
    field :retried_at, :utc_datetime_usec

    timestamps()
  end

  @doc false
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [
      :deployed_at,
      :result,
      :agent_id,
      :content_hash,
      :parent_deployment_id,
      :retried_by_user_id,
      :retry_ordinal,
      :retried_at
    ])
    |> put_assoc(:seeds, Map.get(attrs, :seeds, deployment.seeds))
    |> put_assoc(:subscriptions, Map.get(attrs, :subscriptions, deployment.subscriptions))
    |> validate_number(:retry_ordinal, greater_than: 0)
    |> validate_required([])
  end
end
