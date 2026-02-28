defmodule Sower.Repo.Migrations.AddRetryFieldsToDeployments do
  use Ecto.Migration

  def change do
    alter table(:deployments) do
      add :parent_deployment_id, references(:deployments, on_delete: :nilify_all)
      add :retried_by_user_id, references(:users, on_delete: :nilify_all)
      add :retry_ordinal, :integer
      add :retried_at, :utc_datetime_usec
    end

    create index(:deployments, [:parent_deployment_id])
    create index(:deployments, [:retried_by_user_id])
    create unique_index(:deployments, [:parent_deployment_id, :retry_ordinal])
  end
end
