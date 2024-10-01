defmodule Sower.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories) do
      add :url, :string
      add :org_id, references(:organizations, column: :org_id), null: false

      timestamps()
    end

    create unique_index(:repositories, [:url, :org_id])
  end
end
