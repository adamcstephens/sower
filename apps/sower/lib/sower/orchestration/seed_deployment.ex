defmodule Sower.Orchestration.SeedDeployment do
  use Sower.Schema
  import Ecto.Changeset

  schema "seed_deployment" do
    field :seed_id, :id
    field :deployment_id, :id

    timestamps()
  end

  @doc false
  def changeset(seed_deployment, attrs) do
    seed_deployment
    |> cast(attrs, [])
    |> validate_required([])
  end
end
