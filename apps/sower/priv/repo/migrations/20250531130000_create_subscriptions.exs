defmodule Sower.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add :sid, :string, null: false
      add :org_id, references(:organizations, column: :org_id, type: :uuid), null: false
      add :agent_id, references(:agents, on_delete: :nothing), null: false
      add :seed_id, references(:seeds, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:subscriptions, [:sid])
    create index(:subscriptions, [:org_id])
    create unique_index(:subscriptions, [:agent_id, :org_id, :seed_id])
  end
end
