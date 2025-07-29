defmodule Sower.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments) do
      add :sid, :string, null: false
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false

      add :deployed_at, :utc_datetime

      timestamps()
    end

    create index(:deployments, [:org_id])
    create unique_index(:deployments, :sid)

    create table(:seeds_deployments) do
      add :seed_id, references(:seeds, on_delete: :nothing), null: false
      add :deployment_id, references(:deployments, on_delete: :nothing), null: false

      timestamps()
    end

    create index(:seeds_deployments, [:seed_id])
    create index(:seeds_deployments, [:deployment_id])
    create unique_index(:seeds_deployments, [:seed_id, :deployment_id])

    create table(:subscriptions_deployments) do
      add :subscription_id, references(:subscriptions, on_delete: :nothing), null: false
      add :deployment_id, references(:deployments, on_delete: :nothing), null: false

      timestamps()
    end

    create index(:subscriptions_deployments, [:subscription_id])
    create index(:subscriptions_deployments, [:deployment_id])
    create unique_index(:subscriptions_deployments, [:subscription_id, :deployment_id])
  end
end
