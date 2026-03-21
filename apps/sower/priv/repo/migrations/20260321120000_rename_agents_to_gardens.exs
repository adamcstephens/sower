defmodule Sower.Repo.Migrations.RenameAgentsToGardens do
  use Ecto.Migration

  def change do
    # Rename tables
    rename table(:agents), to: table(:gardens)
    rename table(:agent_seed_generations), to: table(:garden_seed_generations)

    # Rename columns
    rename table(:deployments), :agent_id, to: :garden_id
    rename table(:subscriptions), :agent_id, to: :garden_id
    rename table(:garden_seed_generations), :agent_id, to: :garden_id

    # Rename indexes on gardens (formerly agents)
    execute "ALTER INDEX agents_pkey RENAME TO gardens_pkey",
            "ALTER INDEX gardens_pkey RENAME TO agents_pkey"

    execute "ALTER INDEX agents_org_id_index RENAME TO gardens_org_id_index",
            "ALTER INDEX gardens_org_id_index RENAME TO agents_org_id_index"

    execute "ALTER INDEX agents_sid_index RENAME TO gardens_sid_index",
            "ALTER INDEX gardens_sid_index RENAME TO agents_sid_index"

    # Rename indexes on deployments
    execute "ALTER INDEX deployments_agent_id_index RENAME TO deployments_garden_id_index",
            "ALTER INDEX deployments_garden_id_index RENAME TO deployments_agent_id_index"

    # Rename indexes on subscriptions
    execute "ALTER INDEX subscriptions_agent_id_org_id_seed_name_seed_type_index RENAME TO subscriptions_garden_id_org_id_seed_name_seed_type_index",
            "ALTER INDEX subscriptions_garden_id_org_id_seed_name_seed_type_index RENAME TO subscriptions_agent_id_org_id_seed_name_seed_type_index"

    # Rename indexes on garden_seed_generations (formerly agent_seed_generations)
    execute "ALTER INDEX agent_seed_generations_pkey RENAME TO garden_seed_generations_pkey",
            "ALTER INDEX garden_seed_generations_pkey RENAME TO agent_seed_generations_pkey"

    execute "ALTER INDEX agent_seed_generations_org_id_index RENAME TO garden_seed_generations_org_id_index",
            "ALTER INDEX garden_seed_generations_org_id_index RENAME TO agent_seed_generations_org_id_index"

    execute "ALTER INDEX agent_seed_generations_agent_id_index RENAME TO garden_seed_generations_garden_id_index",
            "ALTER INDEX garden_seed_generations_garden_id_index RENAME TO agent_seed_generations_agent_id_index"

    execute "ALTER INDEX agent_seed_generations_seed_id_index RENAME TO garden_seed_generations_seed_id_index",
            "ALTER INDEX garden_seed_generations_seed_id_index RENAME TO agent_seed_generations_seed_id_index"

    execute "ALTER INDEX agent_seed_generations_profile_id_index RENAME TO garden_seed_generations_profile_id_index",
            "ALTER INDEX garden_seed_generations_profile_id_index RENAME TO agent_seed_generations_profile_id_index"

    execute "ALTER INDEX agent_seed_generations_agent_id_is_current_index RENAME TO garden_seed_generations_garden_id_is_current_index",
            "ALTER INDEX garden_seed_generations_garden_id_is_current_index RENAME TO agent_seed_generations_agent_id_is_current_index"

    execute "ALTER INDEX agent_seed_generations_agent_id_profile_id_index RENAME TO garden_seed_generations_garden_id_profile_id_index",
            "ALTER INDEX garden_seed_generations_garden_id_profile_id_index RENAME TO agent_seed_generations_agent_id_profile_id_index"

    execute "ALTER INDEX agent_seed_generations_agent_id_seed_id_index RENAME TO garden_seed_generations_garden_id_seed_id_index",
            "ALTER INDEX garden_seed_generations_garden_id_seed_id_index RENAME TO agent_seed_generations_agent_id_seed_id_index"

    # Rename foreign key constraints
    execute "ALTER TABLE gardens RENAME CONSTRAINT agents_org_id_fkey TO gardens_org_id_fkey",
            "ALTER TABLE gardens RENAME CONSTRAINT gardens_org_id_fkey TO agents_org_id_fkey"

    execute "ALTER TABLE deployments RENAME CONSTRAINT deployments_agent_id_fkey TO deployments_garden_id_fkey",
            "ALTER TABLE deployments RENAME CONSTRAINT deployments_garden_id_fkey TO deployments_agent_id_fkey"

    execute "ALTER TABLE subscriptions RENAME CONSTRAINT subscriptions_agent_id_fkey TO subscriptions_garden_id_fkey",
            "ALTER TABLE subscriptions RENAME CONSTRAINT subscriptions_garden_id_fkey TO subscriptions_agent_id_fkey"

    execute "ALTER TABLE garden_seed_generations RENAME CONSTRAINT agent_seed_generations_agent_id_fkey TO garden_seed_generations_garden_id_fkey",
            "ALTER TABLE garden_seed_generations RENAME CONSTRAINT garden_seed_generations_garden_id_fkey TO agent_seed_generations_agent_id_fkey"

    execute "ALTER TABLE garden_seed_generations RENAME CONSTRAINT agent_seed_generations_seed_id_fkey TO garden_seed_generations_seed_id_fkey",
            "ALTER TABLE garden_seed_generations RENAME CONSTRAINT garden_seed_generations_seed_id_fkey TO agent_seed_generations_seed_id_fkey"

    execute "ALTER TABLE garden_seed_generations RENAME CONSTRAINT agent_seed_generations_profile_id_fkey TO garden_seed_generations_profile_id_fkey",
            "ALTER TABLE garden_seed_generations RENAME CONSTRAINT garden_seed_generations_profile_id_fkey TO agent_seed_generations_profile_id_fkey"

    execute "ALTER TABLE garden_seed_generations RENAME CONSTRAINT agent_seed_generations_org_id_fkey TO garden_seed_generations_org_id_fkey",
            "ALTER TABLE garden_seed_generations RENAME CONSTRAINT gardens_org_id_fkey TO agent_seed_generations_org_id_fkey"
  end
end
