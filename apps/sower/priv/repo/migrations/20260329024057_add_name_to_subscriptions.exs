defmodule Sower.Repo.Migrations.AddNameToSubscriptions do
  use Ecto.Migration

  def up do
    alter table(:subscriptions) do
      add :name, :string
    end

    execute "UPDATE subscriptions SET name = seed_name WHERE name IS NULL"

    alter table(:subscriptions) do
      modify :name, :string, null: false
    end

    drop unique_index(:subscriptions, [:garden_id, :org_id, :seed_name, :seed_type])
    create unique_index(:subscriptions, [:garden_id, :org_id, :name])
  end

  def down do
    drop unique_index(:subscriptions, [:garden_id, :org_id, :name])
    create unique_index(:subscriptions, [:garden_id, :org_id, :seed_name, :seed_type])

    alter table(:subscriptions) do
      remove :name
    end
  end
end
