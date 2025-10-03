defmodule Sower.Repo.Migrations.CreateSubscriptions do
  use Ecto.Migration

  def change do
    create table(:subscriptions) do
      add(:sid, :string, null: false)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)
      add(:agent_id, references(:agents, on_delete: :delete_all), null: false)

      add(:seed_name, :string)
      add(:seed_type, :string)
      add(:rules, :map)

      timestamps(type: :utc_datetime)
    end

    create(index(:subscriptions, [:sid]))
    create(index(:subscriptions, [:org_id]))
    create(unique_index(:subscriptions, [:agent_id, :org_id, :seed_name, :seed_type]))
  end
end
