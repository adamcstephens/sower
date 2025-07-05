defmodule Sower.Distribution.StorePathDeployment do
  use Sower.Schema
  import Ecto.Changeset

  schema "store_paths_deployments" do
    field :store_path_id, :id
    field :deployment_id, :id

    timestamps()
  end

  @doc false
  def changeset(store_path_deployment, attrs) do
    store_path_deployment
    |> cast(attrs, [])
    |> validate_required([])
  end
end
