defmodule Sower.Repo.Migrations.DropInputRepository do
  use Ecto.Migration

  def change do
    drop_if_exists table(:repositories)
  end
end
