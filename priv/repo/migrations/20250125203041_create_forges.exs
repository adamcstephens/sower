defmodule Sower.Repo.Migrations.CreateForges do
  use Ecto.Migration

  def change do
    create table(:forges) do
      add :name, :string
      add :url, :string
      add :type, :string
      add :client_id, :binary
      add :client_secret, :binary
      add :org_id, references(:organizations, column: :org_id), null: false

      timestamps()
    end
  end
end
