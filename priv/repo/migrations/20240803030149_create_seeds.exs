defmodule Sower.Repo.Migrations.CreateSeeds do
  use Ecto.Migration

  def change do
    create table(:seeds) do
      add :name, :string
      add :seed_type, :string

      timestamps()
    end

    create unique_index(:seeds, [:name, :seed_type])

    create table(:store_paths) do
      add :path, :string

      timestamps()
    end

    create unique_index(:store_paths, [:path])

    create table(:seeds_store_paths) do
      add :seed_id, references(:seeds)
      add :store_path_id, references(:store_paths, on_delete: :delete_all)
    end
  end
end
