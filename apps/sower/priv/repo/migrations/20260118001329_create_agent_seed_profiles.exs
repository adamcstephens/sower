defmodule Sower.Repo.Migrations.CreateAgentSeedProfiles do
  use Ecto.Migration

  def change do
    create table(:nix_profiles) do
      add(:profile_path, :string, null: false)

      timestamps()
    end

    create(unique_index(:nix_profiles, [:profile_path]))

    create table(:agent_seed_profiles) do
      add(:org_id, references(:organizations, column: :org_id, type: :uuid), null: false)

      add(:agent_id, references(:agents, on_delete: :delete_all), null: false)
      add(:seed_id, references(:seeds, on_delete: :restrict), null: false)
      add(:profile_id, references(:nix_profiles, on_delete: :restrict), null: false)

      add(:generation_number, :integer)
      add(:is_current, :boolean, null: false, default: false)
      add(:created_at_generation, :utc_datetime, null: false)

      timestamps()
    end

    create(index(:agent_seed_profiles, [:org_id]))
    create(index(:agent_seed_profiles, [:agent_id]))
    create(index(:agent_seed_profiles, [:seed_id]))
    create(index(:agent_seed_profiles, [:profile_id]))
    create(index(:agent_seed_profiles, [:agent_id, :is_current]))
    create(index(:agent_seed_profiles, [:agent_id, :profile_id]))
    create(unique_index(:agent_seed_profiles, [:agent_id, :seed_id]))
  end
end
