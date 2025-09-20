defmodule Sower.Orchestration.Deployment do
  use Sower.Schema
  import Ecto.Changeset

  alias Sower.Orchestration

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "deployments" do
    field :sid, SowerClient.Schemas.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    many_to_many :subscriptions, Sower.Orchestration.Subscription,
      join_through: Orchestration.SubscriptionDeployment

    many_to_many :seeds, Sower.Seed, join_through: Orchestration.SeedDeployment

    field :deployed_at, :utc_datetime
    field :result, Ecto.Enum, values: [:success, :failure, :partial]

    timestamps()
  end

  @doc false
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:deployed_at, :result])
    |> put_assoc(:seeds, Map.get(attrs, :seeds, deployment.seeds))
    |> put_assoc(:subscriptions, Map.get(attrs, :subscriptions, deployment.subscriptions))
    |> validate_required([])
  end
end
