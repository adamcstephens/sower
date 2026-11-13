defmodule Sower.Repo.Migrations.AddManagedProfileOperations do
  use Ecto.Migration

  def change do
    alter table(:gardens) do
      add :capabilities, {:array, :string}, null: false, default: []
    end

    alter table(:subscriptions) do
      add :retention, :map
      add :origin, :string, null: false, default: "declared"
      add :configured_retention, :map
      add :retention_config_observed, :boolean, null: false, default: false
      add :uninstall_pending, :boolean, null: false, default: false
    end

    create table(:managed_profiles) do
      add :org_id, :uuid, null: false
      add :garden_id, references(:gardens, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :snapshot, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec
      add :uninstall_pending, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_profiles, [:org_id, :garden_id, :name])

    create table(:managed_profile_operations) do
      add :org_id, :uuid, null: false
      add :garden_id, references(:gardens, on_delete: :delete_all), null: false
      add :request_id, :string, null: false
      add :profile_name, :string, null: false
      add :action, :string, null: false
      add :request, :map, null: false
      add :result, :map, null: false
      add :status, :string, null: false, default: "pending"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_profile_operations, [:org_id, :garden_id, :request_id])
  end
end
