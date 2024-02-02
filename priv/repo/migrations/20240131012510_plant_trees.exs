defmodule Sower.Repo.Migrations.PlantTrees do
  use Ecto.Migration

  def change do
    create table(:trees) do
      add :name, :string

      timestamps()
    end

    create unique_index(:trees, :name)
  end
end
