defmodule Sower.Orchestration.SeedDeployment do
  use Sower.Schema
  import Ecto.Changeset

  schema "seeds_deployments" do
    field :seed_id, :id
    field :deployment_id, :id
    field :org_id, Ecto.UUID

    timestamps()
  end

  @doc false
  def changeset(seed_deployment, attrs) do
    seed_deployment
    |> cast(attrs, [])
    |> validate_required([])
  end
end
