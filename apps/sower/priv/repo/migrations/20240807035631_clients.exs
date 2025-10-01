defmodule Sower.Repo.Migrations.Clients do
  use Ecto.Migration

  def change do
    create table(:clients) do
      add(:sid, :string, null: false)
      add(:name, :string)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      timestamps()
    end

    create(unique_index(:clients, [:name, :org_id]))
    create(unique_index(:clients, :sid))
  end
end
