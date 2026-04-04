defmodule Sower.Repo.Migrations.AddBorutaClientIdToGardens do
  use Ecto.Migration

  def change do
    alter table(:gardens) do
      add :oauth_client_id, :string
    end

    create index(:gardens, [:oauth_client_id], unique: true)
  end
end
