defmodule Sower.Repo.Migrations.Clients do
  use Ecto.Migration

  def change do
    create table(:clients) do
      add :name, :string
      add(:org_id, references(:organizations, column: :org_id), null: false)

      timestamps()
    end

    create unique_index(:clients, [:name, :org_id])
  end
end
