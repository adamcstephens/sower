defmodule Sower.Repo.Migrations.AddSeedUniqueArtifact do
  use Ecto.Migration

  def change do
    create(unique_index(:seeds, [:artifact]))
    drop(unique_index(:seeds, [:name, :seed_type, :artifact, :org_id]))
    create(unique_index(:seeds, [:seed_type, :artifact, :org_id]))
  end
end
