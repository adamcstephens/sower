defmodule Sower.Repo.Migrations.CreateSeeds do
  use Ecto.Migration

  def change do
    create table(:seeds) do
      add(:sid, :string, null: false)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      add(:name, :string, null: false)
      add(:seed_type, :string, null: false)
      add(:artifact, :string, null: false)

      timestamps()
    end

    create(unique_index(:seeds, [:id, :org_id]))
    create(unique_index(:seeds, [:name, :seed_type, :artifact, :org_id]))
    create(unique_index(:seeds, [:sid]))
  end
end
