defmodule Sower.Repo.Migrations.AddSeedPathDigestIndex do
  use Ecto.Migration

  def change do
    create unique_index(:store_paths, [:path_digest])
  end
end
