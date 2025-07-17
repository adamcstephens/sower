defmodule Sower.Orchestration.Deployment do
  use Sower.Schema
  import Ecto.Changeset

  alias Sower.Orchestration

  @derive {Jason.Encoder, only: [:sid]}
  @derive {Phoenix.Param, key: :sid}

  schema "deployments" do
    field :sid, Sower.Schema.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    belongs_to :subscription, Orchestration.Subscription

    many_to_many :store_paths, Sower.Nix.StorePath,
      join_through: Orchestration.StorePathDeployment

    field :deployed_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, [:deployed_at])
    |> put_assoc(:store_paths, attrs.store_paths)
    |> put_assoc(:subscription, attrs.subscription)
    |> validate_required([])
  end
end
