defmodule Sower.Repo.Migrations.DropClient do
  use Ecto.Migration

  def change do
    drop table(:clients)
  end
end
