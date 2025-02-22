defmodule Sower.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories) do
      add :sid, :string, null: false
      add :owner, :string, null: false
      add :repo, :string, null: false
      add :url, :string, null: false
      add :webhook_id, :string
      add :webhook_secret, :binary

      add :org_id, references(:organizations, column: :org_id), null: false
      add :forge_id, references(:forges), null: false

      timestamps()
    end

    create index(:repositories, [:org_id])
    create index(:repositories, [:forge_id])
    create unique_index(:repositories, [:owner, :repo, :forge_id])
  end
end
