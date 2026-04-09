defmodule Sower.Repo.Migrations.ReplaceDurableWithOban do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 12)
    execute("DROP SCHEMA IF EXISTS durable CASCADE")
  end

  def down do
    execute("DROP SCHEMA IF EXISTS public_oban CASCADE")
    Oban.Migration.down(version: 1)
  end
end
