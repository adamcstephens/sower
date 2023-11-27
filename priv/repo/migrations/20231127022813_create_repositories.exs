defmodule Sower.Repo.Migrations.CreateRepositories do
  use Ecto.Migration

  def change do
    create table(:repositories) do
      add :url, :string

      timestamps()
    end
  end
end
