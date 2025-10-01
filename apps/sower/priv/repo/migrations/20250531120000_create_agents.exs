defmodule Sower.Repo.Migrations.CreateAgents do
  use Ecto.Migration

  def change do
    create table(:agents) do
      add(:sid, :string, null: false)
      add(:name, :string, null: false)
      add(:local_sid, :string)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      timestamps()
    end

    create(index(:agents, [:org_id]))
    create(unique_index(:agents, :sid))
  end
end
