defmodule Sower.Repo.Migrations.AddSeedsTable do
  use Ecto.Migration

  def change do
    create table(:seeds) do
      add :name, :string
      add :type, :string
      add :out_path, :string

      timestamps()
    end

    create unique_index(:seeds, [:name, :type, :out_path], name: :seeds_unique_indexy)
  end
end
