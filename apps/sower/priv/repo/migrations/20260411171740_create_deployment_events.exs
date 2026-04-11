defmodule Sower.Repo.Migrations.CreateDeploymentEvents do
  use Ecto.Migration

  def change do
    create_query =
      "CREATE TYPE deployment_event_type AS ENUM ('created', 'canceled')"

    drop_query = "DROP TYPE deployment_event_type"
    execute(create_query, drop_query)

    create_query =
      "CREATE TYPE deployment_event_reason AS ENUM ('user_triggered', 'schedule_triggered', 'realtime_triggered', 'retry', 'superseded', 'stale')"

    drop_query = "DROP TYPE deployment_event_reason"
    execute(create_query, drop_query)

    create table(:deployment_events) do
      add :deployment_id, references(:deployments, on_delete: :restrict), null: false
      add :org_id, :uuid, null: false
      add :event, :deployment_event_type, null: false
      add :reason, :deployment_event_reason, null: false
      add :actor_sid, :string, null: false

      timestamps(updated_at: false)
    end

    create index(:deployment_events, [:deployment_id])

    drop index(:deployments, [:retried_by_user_id])

    alter table(:deployments) do
      remove :retried_by_user_id
      remove :retried_at
    end
  end
end
