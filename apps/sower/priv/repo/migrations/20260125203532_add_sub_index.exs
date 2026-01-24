defmodule Sower.Repo.Migrations.AddSubIndex do
  use Ecto.Migration

  def change do
    create index(:subscriptions, [:seed_name, :seed_type])
    drop index(:subscriptions, [:sid])
    create unique_index(:subscriptions, [:sid])
  end
end
