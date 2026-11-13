defmodule Sower.Repo.Migrations.PreserveProfileGenerationIdentity do
  use Ecto.Migration

  def change do
    drop unique_index(:garden_seed_generations, [:garden_id, :seed_id])

    create unique_index(:garden_seed_generations, [:garden_id, :profile_id, :generation_number],
             name: :garden_profile_generation_identity_index
           )
  end
end
