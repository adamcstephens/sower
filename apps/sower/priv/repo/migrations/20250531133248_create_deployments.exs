defmodule Sower.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments) do
      add :sid, :string, null: false
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false

      add :subscription_id, references(:subscriptions, on_delete: :nothing), null: false

      add :deployed_at, :utc_datetime

      timestamps()
    end

    create index(:deployments, [:org_id])
    create unique_index(:deployments, :sid)
  end
end
