defmodule Sower.Repo.Migrations.CreateForges do
  use Ecto.Migration

  def change do
    create table(:forges) do
      add(:sid, :string, null: false)
      add(:name, :string, null: false)
      add(:url, :string, null: false)
      add(:type, :string, null: false)
      add(:client_id, :binary, null: false)
      add(:client_secret, :binary, null: false)
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      timestamps()
    end

    create(index(:forges, :org_id))
    create(index(:forges, :sid))
    create(unique_index(:forges, [:url, :org_id]))
  end
end
