defmodule Sower.Repo.Migrations.AddBorutaClientIdToGardens do
  use Ecto.Migration

  def change do
    alter table(:gardens) do
      add :boruta_client_id, :string
    end

    create index(:gardens, [:boruta_client_id], unique: true)
  end
end
