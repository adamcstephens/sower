defmodule Sower.Repo.Migrations.PreserveDeploymentDestinations do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :request_id, :string
    end

    create unique_index(:deployments, [:garden_id, :request_id])

    alter table(:seed_deployment) do
      add :subscription_sid, :string
      add :profile_name, :string
    end

    drop unique_index(:seed_deployment, [:seed_id, :deployment_id])
    create unique_index(:seed_deployment, [:seed_id, :deployment_id, :subscription_sid])

    create unique_index(:seed_deployment, [:seed_id, :deployment_id],
             name: :seed_deployment_legacy_destination_index,
             where: "subscription_sid IS NULL"
           )
  end
end
