defmodule Sower.Repo.Migrations.Clients do
  use Ecto.Migration

  def change do
    create table(:clients) do
      add :name, :string

      timestamps()
    end

    create unique_index(:clients, [:name])
  end
end
