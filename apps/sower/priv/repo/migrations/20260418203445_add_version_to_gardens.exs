defmodule Sower.Repo.Migrations.AddVersionToGardens do
  use Ecto.Migration

  def change do
    alter table(:gardens) do
      add :version, :string, null: true
    end
  end
end
