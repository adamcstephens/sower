defmodule Sower.Repo.Migrations.AddDurable do
  use Ecto.Migration

  # Durable was replaced by Oban in migration 20260409035412.
  # This migration is kept as a no-op since it already ran in existing databases.
  def up, do: :ok
  def down, do: :ok
end
