defmodule Sower.Repo.Migrations.PreserveProfileGenerationIdentity do
  use Ecto.Migration

  def up do
    alter table(:garden_seed_generations) do
      add :generation_id, :string
      add :generation_path, :text
      add :is_staged, :boolean, null: false, default: false
      add :pinned, :boolean, null: false, default: false
      add :managed, :boolean, null: false, default: false
    end

    execute """
    UPDATE garden_seed_generations
    SET generation_id = CASE WHEN generation_number IS NULL
      THEN 'legacy:seed:' || seed_id::text
      ELSE 'legacy:' || generation_number::text END
    """

    alter table(:garden_seed_generations) do
      modify :generation_id, :string, null: false
    end

    drop unique_index(:garden_seed_generations, [:garden_id, :seed_id])

    create unique_index(:garden_seed_generations, [:garden_id, :profile_id, :generation_id],
             name: :garden_profile_generation_identity_index
           )
  end

  def down do
    raise "Profile-local generation identity cannot be downgraded without losing retained generations"
  end
end
