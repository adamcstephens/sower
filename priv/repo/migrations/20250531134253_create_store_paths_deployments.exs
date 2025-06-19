defmodule Sower.Repo.Migrations.CreateStorePathsDeployments do
  use Ecto.Migration

  def change do
    create table(:store_paths_deployments) do
      add :store_path_id, references(:store_paths, on_delete: :nothing), null: false
      add :deployment_id, references(:deployments, on_delete: :nothing), null: false
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false

      timestamps()
    end

    create index(:store_paths_deployments, [:store_path_id])
    create index(:store_paths_deployments, [:deployment_id])
    create index(:store_paths_deployments, [:org_id])
    create unique_index(:store_paths_deployments, [:store_path_id, :deployment_id])
  end
end
