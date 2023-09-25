defmodule Sower.Repo.Migrations.CreateHooks do
  use Ecto.Migration

  def change do
    create table(:hooks) do
      add :request, :map

      timestamps()
    end
  end
end
