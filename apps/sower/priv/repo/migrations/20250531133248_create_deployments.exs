defmodule Sower.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments) do
      add(:sid, :string, null: false)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      add(:deployed_at, :utc_datetime)
      add(:result, :string)

      timestamps()
    end

    create(index(:deployments, [:org_id]))
    create(unique_index(:deployments, :sid))

    create table(:seed_deployment) do
      add(:seed_id, references(:seeds, on_delete: :delete_all), null: false)
      add(:deployment_id, references(:deployments, on_delete: :delete_all), null: false)

      timestamps()
    end

    create(index(:seed_deployment, [:seed_id]))
    create(index(:seed_deployment, [:deployment_id]))
    create(unique_index(:seed_deployment, [:seed_id, :deployment_id]))

    create table(:subscriptions_deployments) do
      add(:subscription_id, references(:subscriptions, on_delete: :delete_all), null: false)
      add(:deployment_id, references(:deployments, on_delete: :delete_all), null: false)

      timestamps()
    end

    create(index(:subscriptions_deployments, [:subscription_id]))
    create(index(:subscriptions_deployments, [:deployment_id]))
    create(unique_index(:subscriptions_deployments, [:subscription_id, :deployment_id]))
  end
end
