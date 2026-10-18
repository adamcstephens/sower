defmodule Sower.Repo.Migrations.AddExecutionReconciliation do
  use Ecto.Migration

  def change do
    alter table(:executions) do
      add :run_sid, :string
      add :deadline_at, :utc_datetime_usec
      add :cancel_pending, :boolean, null: false, default: false
      add :dropped_log_bytes, :bigint, null: false, default: 0
    end

    execute "UPDATE executions SET run_sid = 'run_' || sid", ""

    alter table(:executions) do
      modify :run_sid, :string, null: false, from: :string
    end

    create unique_index(:executions, [:run_sid])
  end
end
