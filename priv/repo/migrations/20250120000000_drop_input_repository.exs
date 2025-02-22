defmodule Sower.Repo.Migrations.DropInputRepository do
  use Ecto.Migration

  def up do
    drop_if_exists table(:repositories)
  end

  def down, do: :ok
end
