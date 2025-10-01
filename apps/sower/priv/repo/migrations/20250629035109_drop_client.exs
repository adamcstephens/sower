defmodule Sower.Repo.Migrations.DropClient do
  use Ecto.Migration

  def up do
    drop(table(:clients))
  end

  def down do
    create(table(:clients))
  end
end
