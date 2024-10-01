defmodule Sower.Repo.Migrations.CreateSeeds do
  use Ecto.Migration

  def change do
    create table(:seeds) do
      add :name, :string
      add :seed_type, :string
      add :org_id, references(:organizations, column: :org_id), null: false

      timestamps()
    end

    create unique_index(:seeds, [:id, :org_id])

    create table(:store_paths) do
      add :path, :string
      add :org_id, references(:organizations, column: :org_id), null: false

      timestamps()
    end

    create unique_index(:store_paths, [:id, :org_id])

    create table(:seeds_store_paths) do
      add :org_id, :uuid, null: false

      add :seed_id,
          references(:seeds, on_delete: :delete_all, with: [org_id: :org_id], match: :full),
          null: false

      add :store_path_id,
          references(:store_paths, on_delete: :delete_all, with: [org_id: :org_id], match: :full),
          null: false

      timestamps()
    end

    create unique_index(:seeds, [:name, :seed_type, :org_id])
    create unique_index(:store_paths, [:path, :org_id])
    create unique_index(:seeds_store_paths, [:seed_id, :store_path_id, :org_id])
  end
end
