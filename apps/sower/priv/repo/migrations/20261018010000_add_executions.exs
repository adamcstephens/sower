defmodule Sower.Repo.Migrations.AddExecutions do
  use Ecto.Migration

  def change do
    create table(:execution_builders, primary_key: false) do
      add :garden_id, references(:gardens, on_delete: :delete_all), primary_key: true
      add :org_id, :uuid, null: false
      add :session, :string, null: false
      add :capability, :map, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end

    create table(:executions) do
      add :sid, :string, null: false
      add :run_sid, :string, null: false
      add :org_id, :uuid, null: false
      add :actor_sid, :string, null: false
      add :request, :map, null: false
      add :state, :string, null: false, default: "queued"
      add :queue_reason, :string
      add :garden_id, references(:gardens)
      add :session, :string
      add :attempt, :integer, null: false, default: 0
      add :queue_expires_at, :utc_datetime_usec, null: false
      add :deadline_at, :utc_datetime_usec
      add :cancel_pending, :boolean, null: false, default: false
      add :result, :map
      add :cursor, :bigint, null: false, default: 0
      add :log_bytes, :bigint, null: false, default: 0
      add :dropped_log_bytes, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:executions, [:sid])
    create unique_index(:executions, [:run_sid])
    create index(:executions, [:state, :inserted_at])
    create index(:executions, [:org_id, :sid])

    create table(:execution_events) do
      add :execution_id, references(:executions, on_delete: :delete_all), null: false
      add :org_id, :uuid, null: false
      add :sequence, :bigint, null: false
      add :payload, :map, null: false
    end

    create unique_index(:execution_events, [:execution_id, :sequence])
  end
end
