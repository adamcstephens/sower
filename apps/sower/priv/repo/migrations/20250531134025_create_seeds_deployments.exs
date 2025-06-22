defmodule Sower.Repo.Migrations.CreateSeedsDeployments do
  use Ecto.Migration

  def change do
    create table(:seeds_deployments) do
      add :seed_id, references(:seeds, on_delete: :nothing)
      add :deployment_id, references(:deployments, on_delete: :nothing)
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false

      timestamps()
    end

    create index(:seeds_deployments, [:seed_id])
    create index(:seeds_deployments, [:deployment_id])
    create index(:seeds_deployments, [:org_id])
    create unique_index(:seeds_deployments, [:seed_id, :deployment_id])
  end
end
