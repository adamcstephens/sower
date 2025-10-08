defmodule Sower.Repo.Migrations.AddSeedTags do
  use Ecto.Migration

  def change do
    create table(:seed_tags) do
      add :seed_id, references(:seeds, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :text, null: false
    end

    create index(:seed_tags, [:seed_id])
    create index(:seed_tags, [:key])
    create index(:seed_tags, [:key, :value])
    create index(:seed_tags, [:value])
    create unique_index(:seed_tags, [:seed_id, :key, :value])
  end
end
