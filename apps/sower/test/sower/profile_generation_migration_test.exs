unless Code.ensure_loaded?(Sower.Repo.Migrations.PreserveProfileGenerationIdentity) do
  Code.require_file(
    "../../priv/repo/migrations/20261113040000_preserve_profile_generation_identity.exs",
    __DIR__
  )
end

defmodule Sower.ProfileGenerationMigrationTest do
  use Sower.DataCase

  alias Sower.Orchestration.GardenSeedGeneration
  alias Sower.Repo.Migrations.PreserveProfileGenerationIdentity
  alias SowerClient.Orchestration.{GardenSeedProfile, GardenSeedsReport}

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  test "backfills populated legacy generations without losing identity and reconciles old reports" do
    first_org = organization_fixture()
    Repo.put_org_id(first_org.org_id)
    garden = garden_fixture()
    numbered_seed = seed_fixture()
    unnumbered_seed = seed_fixture()
    first_profile = nix_profile_fixture(%{profile_path: "/nix/var/nix/profiles/system"})

    second_profile =
      nix_profile_fixture(%{profile_path: "/home/alice/.local/state/nix/profiles/home-manager"})

    second_org = organization_fixture()
    Repo.put_org_id(second_org.org_id)
    other_garden = garden_fixture()
    other_seed = seed_fixture()
    created = ~U[2026-10-01 12:00:00Z]
    versions = Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows

    Repo.query!("DROP INDEX garden_profile_generation_identity_index")

    Repo.query!("""
    ALTER TABLE garden_seed_generations
      DROP COLUMN generation_id,
      DROP COLUMN generation_path,
      DROP COLUMN is_staged,
      DROP COLUMN pinned,
      DROP COLUMN managed
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX garden_seed_generations_garden_id_seed_id_index
    ON garden_seed_generations (garden_id, seed_id)
    """)

    numbered_id =
      insert_legacy(
        first_org.org_id,
        garden.id,
        numbered_seed.id,
        first_profile.id,
        42,
        true,
        created
      )

    unnumbered_id =
      insert_legacy(
        first_org.org_id,
        garden.id,
        unnumbered_seed.id,
        second_profile.id,
        nil,
        false,
        created
      )

    other_id =
      insert_legacy(
        second_org.org_id,
        other_garden.id,
        other_seed.id,
        first_profile.id,
        42,
        true,
        created
      )

    before = legacy_rows()

    Repo.put_org_id(nil)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               Ecto.Migration.Runner.run(
                 Repo,
                 Repo.config(),
                 20_261_113_040_000,
                 PreserveProfileGenerationIdentity,
                 :forward,
                 :up,
                 :up,
                 log: false
               )

               :ok
             end)

    assert legacy_rows() == before
    assert Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows == versions
    rows = Repo.all(GardenSeedGeneration, skip_org_id: true)

    assert Map.new(rows, &{&1.id, &1.generation_id}) == %{
             numbered_id => "legacy:42",
             unnumbered_id => "legacy:seed:#{unnumbered_seed.id}",
             other_id => "legacy:42"
           }

    assert Enum.all?(rows, &(not &1.managed and not &1.pinned and not &1.is_staged))

    Repo.put_org_id(first_org.org_id)

    report = %GardenSeedsReport{
      profiles: [
        %GardenSeedProfile{
          profile_path: first_profile.profile_path,
          generations: [
            legacy_generation(
              numbered_seed.artifact,
              first_profile.profile_path <> "-42-link",
              42,
              true,
              created
            )
          ]
        },
        %GardenSeedProfile{
          profile_path: second_profile.profile_path,
          generations: [
            legacy_generation(
              unnumbered_seed.artifact,
              second_profile.profile_path,
              nil,
              false,
              created
            )
          ]
        }
      ]
    }

    assert {:ok, :ok} = GardenSeedGeneration.update_garden_seed_generations(report, garden)

    assert MapSet.new(GardenSeedGeneration.list_garden_seed_generation(garden), & &1.id) ==
             MapSet.new([numbered_id, unnumbered_id])

    assert Repo.get!(GardenSeedGeneration, other_id, skip_org_id: true).garden_id ==
             other_garden.id

    attrs = %{generation_number: 43, is_current: false, created_at_generation: created}

    assert {:ok, repeated} =
             GardenSeedGeneration.upsert_garden_generation(
               garden.id,
               first_profile.id,
               numbered_seed.id,
               attrs
             )

    assert {:ok, independent} =
             GardenSeedGeneration.upsert_garden_generation(
               garden.id,
               second_profile.id,
               numbered_seed.id,
               %{attrs | generation_number: 42}
             )

    assert length(Enum.uniq([numbered_id, repeated.id, independent.id])) == 3
    assert length(GardenSeedGeneration.list_garden_seed_generation(garden)) == 4
    assert Repo.get!(GardenSeedGeneration, numbered_id).generation_id == "legacy:42"
  end

  defp insert_legacy(org_id, garden_id, seed_id, profile_id, number, current, created) do
    [[id]] =
      Repo.query!(
        """
        INSERT INTO garden_seed_generations
          (org_id, garden_id, seed_id, profile_id, generation_number, is_current,
           created_at_generation, inserted_at, updated_at)
        VALUES ($1::text::uuid, $2, $3, $4, $5, $6, $7, $7, $7)
        RETURNING id
        """,
        [org_id, garden_id, seed_id, profile_id, number, current, DateTime.to_naive(created)]
      ).rows

    id
  end

  defp legacy_rows do
    Repo.query!("""
    SELECT id, org_id, garden_id, seed_id, profile_id, generation_number,
           is_current, created_at_generation, inserted_at, updated_at
    FROM garden_seed_generations ORDER BY id
    """).rows
  end

  defp legacy_generation(artifact, link, number, current, created) do
    %SowerClient.Orchestration.GardenSeedGeneration{
      path: artifact,
      link: link,
      created: DateTime.to_iso8601(created),
      generation_number: number,
      is_current: current
    }
  end
end
