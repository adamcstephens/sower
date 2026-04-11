defmodule Sower.OrchestrationTest do
  use Sower.DataCase

  alias Sower.Orchestration
  import Sower.AccountsFixtures
  import Sower.SeedFixtures

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "gardens" do
    alias Sower.Orchestration.Garden

    import Sower.OrchestrationFixtures

    @invalid_attrs %{name: nil}

    test "list_gardens/0 returns all gardens" do
      garden = garden_fixture()
      assert Orchestration.list_gardens() == [garden]
    end

    test "get_garden!/1 returns the garden with given id" do
      garden = garden_fixture()
      assert Orchestration.get_garden!(garden.id) == garden
    end

    test "create_garden/1 with valid data creates a garden" do
      valid_attrs = %{name: "some garden"}

      assert {:ok, %Garden{} = garden} = Orchestration.create_garden(valid_attrs)
      assert garden.name == "some garden"
    end

    test "create_garden/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Orchestration.create_garden(@invalid_attrs)
    end

    test "update_garden/2 with valid data updates the garden" do
      garden = garden_fixture()
      update_attrs = %{name: "updated garden"}

      assert {:ok, %Garden{} = garden} = Orchestration.update_garden(garden, update_attrs)
      assert garden.name == "updated garden"
    end

    test "update_garden/2 with invalid data returns error changeset" do
      garden = garden_fixture()
      assert {:error, %Ecto.Changeset{}} = Orchestration.update_garden(garden, @invalid_attrs)
      assert garden == Orchestration.get_garden!(garden.id)
    end

    test "delete_garden/1 deletes the garden" do
      garden = garden_fixture()
      assert {:ok, %Garden{}} = Orchestration.delete_garden(garden)
      assert_raise Ecto.NoResultsError, fn -> Orchestration.get_garden!(garden.id) end
    end

    test "change_garden/1 returns a garden changeset" do
      garden = garden_fixture()
      assert %Ecto.Changeset{} = Orchestration.change_garden(garden)
    end
  end

  describe "subscriptions" do
    import Sower.OrchestrationFixtures

    test "create_subscription/1 updates rules on conflict" do
      garden = garden_fixture()

      # Create initial subscription with rules
      {:ok, sub1} =
        Orchestration.create_subscription(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: "eq", value: "main"}]
        })

      assert length(sub1.rules) == 1
      assert hd(sub1.rules).value == "main"

      # Re-create with different rules (same garden, seed_name, seed_type)
      {:ok, sub2} =
        Orchestration.create_subscription(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: "eq", value: "develop"}]
        })

      # Should be the same subscription (same id)
      assert sub2.id == sub1.id

      # Rules should be updated
      assert length(sub2.rules) == 1
      assert hd(sub2.rules).value == "develop"

      # Verify by fetching fresh from DB
      refreshed = Orchestration.get_subscription!(sub1.id)
      assert hd(refreshed.rules).value == "develop"
    end
  end

  describe "match_seed/1" do
    import Sower.OrchestrationFixtures

    test "returns nil when no seed matches name and type" do
      garden = garden_fixture()

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "nonexistent",
          seed_type: "nixos"
        })

      assert Orchestration.match_seed(subscription) == nil
    end

    test "returns seed when name and type match with no rules" do
      garden = garden_fixture()
      seed = seed_fixture(%{name: "myhost", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos"
        })

      matched = Orchestration.match_seed(subscription)
      assert matched.id == seed.id
    end

    test "returns seed when single rule matches" do
      garden = garden_fixture()

      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos",
          tags: [%{key: "branch", value: "main"}]
        })

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: :eq, value: "main"}]
        })

      matched = Orchestration.match_seed(subscription)
      assert matched.id == seed.id
    end

    test "returns seed when all rules match" do
      garden = garden_fixture()

      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos",
          tags: [
            %{key: "branch", value: "main"},
            %{key: "repo", value: "http://example.com/repo"}
          ]
        })

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [
            %{key: "branch", op: :eq, value: "main"},
            %{key: "repo", op: :eq, value: "http://example.com/repo"}
          ]
        })

      matched = Orchestration.match_seed(subscription)
      assert matched.id == seed.id
      assert length(matched.tags) == 2
    end

    test "returns seed when all rules match even if seed has more tags" do
      garden = garden_fixture()

      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos",
          tags: [
            %{key: "branch", value: "main"},
            %{key: "repo", value: "http://example.com/repo"},
            %{key: "sometag", value: "somevalue"}
          ]
        })

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [
            %{key: "branch", op: :eq, value: "main"},
            %{key: "repo", op: :eq, value: "http://example.com/repo"}
          ]
        })

      matched = Orchestration.match_seed(subscription)
      assert matched.id == seed.id
    end

    test "returns nil when rule does not match" do
      garden = garden_fixture()

      seed_fixture(%{
        name: "myhost",
        seed_type: "nixos",
        tags: [%{key: "branch", value: "dev"}]
      })

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: :eq, value: "main"}]
        })

      assert Orchestration.match_seed(subscription) == nil
    end

    test "returns nil when only some rules match" do
      garden = garden_fixture()

      seed_fixture(%{
        name: "myhost",
        seed_type: "nixos",
        tags: [
          %{key: "branch", value: "main"}
        ]
      })

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [
            %{key: "branch", op: :eq, value: "main"},
            %{key: "repo", op: :eq, value: "http://example.com/repo"}
          ]
        })

      assert Orchestration.match_seed(subscription) == nil
    end

    test "returns latest seed when multiple seeds match" do
      garden = garden_fixture()

      artifact1 = random_nix_artifact()
      artifact2 = random_nix_artifact()

      _older_seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos",
          artifact: artifact1,
          tags: [%{key: "branch", value: "main"}]
        })

      # Sleep to ensure different timestamps
      Process.sleep(10)

      _newer_seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos",
          artifact: artifact2,
          tags: [%{key: "branch", value: "main"}]
        })

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: :eq, value: "main"}]
        })

      matched = Orchestration.match_seed(subscription)
      # Verify we got the newer seed by checking the artifact
      # The newer seed should have artifact2 since it was created second
      assert matched.artifact == artifact2
    end
  end

  describe "nix_profiles" do
    alias Sower.Orchestration.NixProfile

    test "changeset/2 validates required gardens" do
      changeset = NixProfile.changeset(%NixProfile{}, %{})
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).profile_path
    end

    test "changeset/2 accepts valid attributes" do
      changeset =
        NixProfile.changeset(%NixProfile{}, %{profile_path: "/nix/var/nix/profiles/system"})

      assert changeset.valid?
    end

    test "find_or_create/1 creates a new profile" do
      assert {:ok, profile} = NixProfile.find_or_create("/nix/var/nix/profiles/system")
      assert profile.profile_path == "/nix/var/nix/profiles/system"
      assert profile.id != nil
    end

    test "find_or_create/1 returns existing profile" do
      {:ok, profile1} = NixProfile.find_or_create("/nix/var/nix/profiles/system")
      {:ok, profile2} = NixProfile.find_or_create("/nix/var/nix/profiles/system")

      assert profile1.id == profile2.id
    end

    test "find_or_create!/1 creates a new profile" do
      profile = NixProfile.find_or_create!("/nix/var/nix/profiles/system")
      assert profile.profile_path == "/nix/var/nix/profiles/system"
    end

    test "get_by_path/1 returns existing profile" do
      {:ok, created} = NixProfile.find_or_create("/nix/var/nix/profiles/system")
      found = NixProfile.get_by_path("/nix/var/nix/profiles/system")

      assert found.id == created.id
    end

    test "get_by_path/1 returns nil for non-existent profile" do
      assert NixProfile.get_by_path("/nonexistent/path") == nil
    end
  end

  describe "garden_seed_generations" do
    alias Sower.Orchestration.{GardenSeedGeneration, NixProfile}

    import Sower.OrchestrationFixtures

    test "changeset/2 validates required gardens" do
      changeset = GardenSeedGeneration.changeset(%GardenSeedGeneration{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.org_id
      assert "can't be blank" in errors.garden_id
      assert "can't be blank" in errors.seed_id
      assert "can't be blank" in errors.profile_id
      assert "can't be blank" in errors.created_at_generation
    end

    test "changeset/2 accepts valid attributes" do
      garden = garden_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()

      changeset =
        GardenSeedGeneration.changeset(%GardenSeedGeneration{}, %{
          org_id: Sower.Repo.get_org_id(),
          garden_id: garden.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 42,
          is_current: true,
          created_at_generation: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "list_for_garden/1 returns all profiles for garden ordered by generation_number desc" do
      garden = garden_fixture()
      seed1 = seed_fixture()
      seed2 = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      asp1 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed1.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: false,
          created_at_generation: now
        })

      asp2 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed2.id,
          profile_id: profile.id,
          generation_number: 2,
          is_current: true,
          created_at_generation: now
        })

      result = Orchestration.list_garden_seed_generation(garden)

      assert length(result) == 2
      assert Enum.at(result, 0).id == asp2.id
      assert Enum.at(result, 1).id == asp1.id
    end

    test "list_current_seed_generation/1 returns only current profiles" do
      garden = garden_fixture()
      seed1 = seed_fixture()
      seed2 = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      _asp1 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed1.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: false,
          created_at_generation: now
        })

      asp2 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed2.id,
          profile_id: profile.id,
          generation_number: 2,
          is_current: true,
          created_at_generation: now
        })

      result = Orchestration.list_current_seed_generation(garden)

      assert length(result) == 1
      assert hd(result).id == asp2.id
    end

    test "list_for_garden_profile/2 returns profiles for specific garden and profile" do
      garden = garden_fixture()
      seed1 = seed_fixture()
      seed2 = seed_fixture()
      profile1 = nix_profile_fixture(%{profile_path: "/nix/var/nix/profiles/system"})
      profile2 = nix_profile_fixture(%{profile_path: "~/.local/state/nix/profiles/home-manager"})
      now = DateTime.utc_now()

      asp1 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed1.id,
          profile_id: profile1.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      _asp2 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed2.id,
          profile_id: profile2.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      result = Orchestration.list_garden_seed_generation_profile(garden.id, profile1.id)

      assert length(result) == 1
      assert hd(result).id == asp1.id
    end

    test "upsert_from_report/4 inserts new profile" do
      garden = garden_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      attrs = %{
        generation_number: 42,
        is_current: true,
        created_at_generation: now
      }

      assert {:ok, asp} =
               Orchestration.upsert_garden_generation(garden.id, profile.id, seed.id, attrs)

      assert asp.generation_number == 42
      assert asp.is_current == true
    end

    @tag :capture_log
    test "upsert_from_report/4 updates existing profile on conflict" do
      garden = garden_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      attrs1 = %{
        generation_number: 41,
        is_current: false,
        created_at_generation: now
      }

      {:ok, asp1} = Orchestration.upsert_garden_generation(garden.id, profile.id, seed.id, attrs1)
      assert asp1.generation_number == 41

      attrs2 = %{
        generation_number: 42,
        is_current: true,
        created_at_generation: now
      }

      {:ok, asp2} = Orchestration.upsert_garden_generation(garden.id, profile.id, seed.id, attrs2)
      assert asp2.id == asp1.id
      assert asp2.generation_number == 42
      assert asp2.is_current == true
    end

    @tag :capture_log
    test "unique constraint on garden_id and seed_id" do
      garden = garden_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      _asp1 =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      # Attempting to insert a duplicate should fail
      result =
        %GardenSeedGeneration{}
        |> GardenSeedGeneration.changeset(%{
          org_id: Sower.Repo.get_org_id(),
          garden_id: garden.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 2,
          is_current: true,
          created_at_generation: now
        })
        |> Sower.Repo.insert()

      assert {:error, changeset} = result
      assert "has already been taken" in errors_on(changeset).garden_id
    end

    test "deleting garden cascades to garden_seed_generations" do
      garden = garden_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      asp =
        garden_seed_generation_fixture(%{
          garden_id: garden.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      {:ok, _} = Orchestration.delete_garden(garden)

      assert Orchestration.list_garden_seed_generation(garden) == []
      assert Sower.Repo.get(GardenSeedGeneration, asp.id) == nil
    end
  end

  describe "update_garden_seed_generations/2 with auto-registration" do
    alias Sower.Orchestration.{GardenSeedGeneration, NixProfile}
    alias Sower.Orchestration.Seed

    import Sower.OrchestrationFixtures

    test "auto-registers unknown artifacts as seeds" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"

      report = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact,
                link: "/nix/var/nix/profiles/system-42-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 42,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)

      # Verify seed was auto-registered
      seed = Seed.get_by_artifact(artifact)
      assert seed != nil
      assert seed.name == "testhost"
      assert seed.seed_type == "nixos"

      assert Enum.any?(seed.tags, fn tag ->
               tag.key == "garden_source" && tag.value == garden.sid
             end)

      assert Enum.any?(seed.tags, fn tag ->
               tag.key == "nixos_version" && tag.value == "25.11"
             end)

      # Verify garden_seed_generation was created
      profiles = Orchestration.list_garden_seed_generation(garden)
      assert length(profiles) == 1
      assert hd(profiles).seed_id == seed.id
      assert hd(profiles).is_current == true
    end

    test "auto-registers multiple generations and sets is_current correctly" do
      garden = garden_fixture()
      artifact_current = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"
      artifact_previous = "/nix/store/#{unique_hash()}-nixos-system-testhost-24.04"

      report = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact_current,
                link: "/nix/var/nix/profiles/system-42-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 42,
                is_current: true
              },
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact_previous,
                link: "/nix/var/nix/profiles/system-41-link",
                created: DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -86400, :second)),
                generation_number: 41,
                is_current: false
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)

      # Both seeds should be auto-registered
      assert Seed.get_by_artifact(artifact_current) != nil
      assert Seed.get_by_artifact(artifact_previous) != nil

      # Both should have garden_seed_generations
      profiles = Orchestration.list_garden_seed_generation(garden)
      assert length(profiles) == 2

      # Only one should be current
      current_profiles = Enum.filter(profiles, & &1.is_current)
      assert length(current_profiles) == 1
      assert hd(current_profiles).generation_number == 42
    end

    test "includes profile tags in auto-registered seeds" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-home-manager-generation"

      report = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/home/alice/.local/state/nix/profiles/home-manager",
            tags: %{"user" => "alice"},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact,
                link: "/home/alice/.local/state/nix/profiles/home-manager-5-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 5,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)

      seed = Seed.get_by_artifact(artifact)
      assert seed.seed_type == "home-manager"
      assert Enum.any?(seed.tags, fn tag -> tag.key == "user" && tag.value == "alice" end)
      assert Enum.any?(seed.tags, fn tag -> tag.key == "garden_source" end)
    end

    test "uses existing seed when artifact is already known" do
      garden = garden_fixture()
      existing = seed_fixture()

      report = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: existing.artifact,
                link: "/nix/var/nix/profiles/system-1-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 1,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)

      # Should use existing seed, not create a new one
      profiles = Orchestration.list_garden_seed_generation(garden)
      assert length(profiles) == 1
      assert hd(profiles).seed_id == existing.id
    end

    test "deletes stale garden_seed_generations for removed generations" do
      garden = garden_fixture()
      artifact1 = "/nix/store/#{unique_hash()}-nixos-system-testhost-1"
      artifact2 = "/nix/store/#{unique_hash()}-nixos-system-testhost-2"

      # First report with two generations
      report1 = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact1,
                link: "/nix/var/nix/profiles/system-1-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 1,
                is_current: false
              },
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact2,
                link: "/nix/var/nix/profiles/system-2-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 2,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report1, garden)
      assert length(Orchestration.list_garden_seed_generation(garden)) == 2

      # Second report with only one generation (simulating garbage collection)
      report2 = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact2,
                link: "/nix/var/nix/profiles/system-2-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 2,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report2, garden)

      # Should only have one garden_seed_generation now
      profiles = Orchestration.list_garden_seed_generation(garden)
      assert length(profiles) == 1
      assert hd(profiles).generation_number == 2
    end

    test "repeated identical reports do not advance generation id sequence" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"
      created_at = DateTime.to_iso8601(DateTime.utc_now())

      report = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: artifact,
                link: "/nix/var/nix/profiles/system-42-link",
                created: created_at,
                generation_number: 42,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)
      first_sequence_value = garden_seed_generation_sequence_last_value()

      [first_row] = Orchestration.list_garden_seed_generation(garden)

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)
      second_sequence_value = garden_seed_generation_sequence_last_value()

      [second_row] = Orchestration.list_garden_seed_generation(garden)

      assert second_row.id == first_row.id
      assert second_sequence_value == first_sequence_value
    end

    test "handles multiple profiles (NixOS + home-manager)" do
      garden = garden_fixture()
      nixos_artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost"
      hm_artifact = "/nix/store/#{unique_hash()}-home-manager-generation"

      report = %SowerClient.Orchestration.GardenSeedsReport{
        profiles: [
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/nix/var/nix/profiles/system",
            tags: %{},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: nixos_artifact,
                link: "/nix/var/nix/profiles/system-42-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 42,
                is_current: true
              }
            ]
          },
          %SowerClient.Orchestration.GardenSeedProfile{
            profile_path: "/home/testuser/.local/state/nix/profiles/home-manager",
            tags: %{"user" => "testuser"},
            generations: [
              %SowerClient.Orchestration.GardenSeedGeneration{
                path: hm_artifact,
                link: "/home/testuser/.local/state/nix/profiles/home-manager-10-link",
                created: DateTime.to_iso8601(DateTime.utc_now()),
                generation_number: 10,
                is_current: true
              }
            ]
          }
        ]
      }

      assert {:ok, :ok} = Orchestration.update_garden_seed_generations(report, garden)

      profiles = Orchestration.list_garden_seed_generation(garden)
      assert length(profiles) == 2

      nixos_seed = Seed.get_by_artifact(nixos_artifact)
      hm_seed = Seed.get_by_artifact(hm_artifact)

      assert nixos_seed.seed_type == "nixos"
      assert hm_seed.seed_type == "home-manager"
      assert Enum.any?(hm_seed.tags, fn tag -> tag.key == "user" && tag.value == "testuser" end)

      # Verify correct nix_profiles were created
      nixos_profile = NixProfile.get_by_path("/nix/var/nix/profiles/system")
      hm_profile = NixProfile.get_by_path("/home/testuser/.local/state/nix/profiles/home-manager")

      assert nixos_profile != nil
      assert hm_profile != nil
    end
  end

  describe "handle_deployment_request/2" do
    import Sower.OrchestrationFixtures

    @tag :capture_log
    test "returns immediate request_id for valid deployment request", %{organization: _org} do
      garden = garden_fixture()
      _seed = seed_fixture(%{name: "testhost", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "testhost",
          seed_type: "nixos"
        })

      {:ok, request} =
        SowerClient.Orchestration.DeploymentRequest.new(%{
          subscription_sids: [subscription.sid],
          force: false
        })

      assert {:ok, request_id, pid} = Orchestration.handle_deployment_request(request, garden)
      assert is_binary(request_id)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end

    test "returns error for deployment request with unauthorized subscription", %{
      organization: _org
    } do
      garden1 = garden_fixture()
      garden2 = garden_fixture()

      # Create subscription for garden1
      subscription =
        subscription_fixture(%{
          garden_id: garden1.id,
          seed_name: "testhost",
          seed_type: "nixos"
        })

      # Try to use garden2's subscription with garden1's context (should fail)
      {:ok, request} =
        SowerClient.Orchestration.DeploymentRequest.new(%{
          subscription_sids: [subscription.sid],
          force: false
        })

      # This should be rejected because garden2 doesn't own the subscription
      result = Orchestration.handle_deployment_request(request, garden2)
      assert result == {:error, :unauthorized}
    end

    @tag :capture_log
    test "process_deployment returns request_id and starts async task", %{organization: _org} do
      garden = garden_fixture()
      _seed = seed_fixture(%{name: "testhost", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "testhost",
          seed_type: "nixos"
        })

      request_id = "dr_test_#{System.unique_integer([:positive])}"

      assert {:ok, ^request_id, pid} =
               Orchestration.process_deployment(request_id, [subscription], garden)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end

    @tag :capture_log
    test "process_deployment handles error case with no matching seeds", %{organization: _org} do
      garden = garden_fixture()

      # Create subscription with no matching seed
      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "nonexistent",
          seed_type: "nixos"
        })

      request_id = "dr_test_error_#{System.unique_integer([:positive])}"

      assert {:ok, ^request_id, pid} =
               Orchestration.process_deployment(request_id, [subscription], garden)

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5000
    end
  end

  describe "reconcile_deployments_on_connect/2" do
    import Sower.OrchestrationFixtures

    test "replays unresolved deployments and updates dispatch timestamp", %{organization: _org} do
      garden = garden_fixture()
      seed = seed_fixture(%{name: "replay-host", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      unresolved =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: nil,
          deployed_at: nil
        })

      _terminal =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: :success,
          state: :completed,
          deployed_at: DateTime.utc_now()
        })

      replayed_at = DateTime.utc_now() |> DateTime.truncate(:second)
      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:#{garden.sid}")

      assert {:ok, %{replayed: replayed, cancelled: [], overdue: []}} =
               Orchestration.Deployment.reconcile_deployments_on_connect(garden, now: replayed_at)

      assert Enum.map(replayed, & &1.sid) == [unresolved.sid]

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "deployment",
        payload: payload
      }

      assert topic == "garden:#{garden.sid}"
      assert payload.sid == unresolved.sid
      assert payload.skipped == false
      assert is_binary(payload.request_id)

      refreshed = Orchestration.get_deployment_sid!(unresolved.sid)

      assert DateTime.truncate(refreshed.last_dispatched_at, :second) ==
               DateTime.truncate(replayed_at, :second)
    end

    test "cancels unresolved deployments superseded by overdue schedules", %{organization: _org} do
      garden = garden_fixture()
      seed = seed_fixture(%{name: "cancel-host", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type,
          schedule: "* * * * *"
        })

      unresolved =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: nil,
          deployed_at: nil
        })

      assert {:ok, %{replayed: [], cancelled: cancelled, overdue: overdue}} =
               Orchestration.Deployment.reconcile_deployments_on_connect(garden)

      assert length(cancelled) == 1
      assert hd(cancelled).sid == unresolved.sid
      assert length(overdue) == 1
      assert hd(overdue).sid == subscription.sid

      refreshed = Orchestration.get_deployment_sid!(unresolved.sid)
      assert refreshed.state == :canceled
      assert refreshed.result == :failure
    end
  end

  describe "finalize_stale_deployments/1" do
    import Sower.OrchestrationFixtures

    test "finalizes stale unresolved deployments and keeps fresh unresolved unchanged", %{
      organization: _org
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old_dispatch = DateTime.add(now, -8_000, :second)
      fresh_dispatch = DateTime.add(now, -100, :second)
      garden = garden_fixture()

      stale =
        deployment_fixture(%{
          garden_id: garden.id,
          result: nil,
          deployed_at: nil,
          state: :dispatched,
          last_dispatched_at: old_dispatch
        })

      fresh =
        deployment_fixture(%{
          garden_id: garden.id,
          result: nil,
          deployed_at: nil,
          state: :dispatched,
          last_dispatched_at: fresh_dispatch
        })

      assert {:ok, 1} =
               Orchestration.finalize_stale_deployments(
                 now: now,
                 stale_after_seconds: 3_600,
                 batch_size: 10
               )

      stale = Orchestration.get_deployment_sid!(stale.sid)
      assert stale.result == :failure
      assert stale.state == :stale
      assert stale.deployed_at == now

      fresh = Orchestration.get_deployment_sid!(fresh.sid)
      assert is_nil(fresh.result)
      assert fresh.state == :dispatched
      assert is_nil(fresh.deployed_at)
    end

    test "stale finalization unblocks retry creation for abandoned child retries", %{
      organization: org
    } do
      user = user_fixture(%{org_id: org.org_id})
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old_dispatch = DateTime.add(now, -10_000, :second)
      garden = garden_fixture()

      parent =
        deployment_fixture(%{
          garden_id: garden.id,
          result: :success,
          state: :completed,
          deployed_at: DateTime.utc_now()
        })

      _child =
        deployment_fixture(%{
          garden_id: garden.id,
          parent_deployment_id: parent.id,
          retry_ordinal: 1,
          retried_by_user_id: user.id,
          retried_at: DateTime.utc_now(),
          result: nil,
          state: :dispatched,
          deployed_at: nil,
          last_dispatched_at: old_dispatch
        })

      assert {:error, :retry_in_progress} = Orchestration.retry_deployment(parent, user.id)

      assert {:ok, 1} =
               Orchestration.finalize_stale_deployments(
                 now: now,
                 stale_after_seconds: 3_600,
                 batch_size: 10
               )

      assert {:ok, _retry} = Orchestration.retry_deployment(parent, user.id)
    end

    test "late deployment results can still update stale-finalized deployments", %{
      organization: _org
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      old_dispatch = DateTime.add(now, -8_000, :second)
      later = DateTime.add(now, 60, :second)
      garden = garden_fixture()

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          result: nil,
          state: :dispatched,
          deployed_at: nil,
          last_dispatched_at: old_dispatch
        })

      assert {:ok, 1} =
               Orchestration.finalize_stale_deployments(
                 now: now,
                 stale_after_seconds: 3_600,
                 batch_size: 10
               )

      assert {:ok, _updated} =
               Orchestration.record_deployment(
                 SowerClient.Orchestration.DeploymentResult.cast!(%{
                   request_id: "request_late_result",
                   deployment_sid: deployment.sid,
                   result: :success,
                   deployed_at: DateTime.to_iso8601(later)
                 })
               )

      refreshed = Orchestration.get_deployment_sid!(deployment.sid)
      assert refreshed.result == :success
      assert refreshed.state == :completed
      assert refreshed.deployed_at == later
    end
  end

  describe "request_deployment/1 force behavior" do
    import Sower.OrchestrationFixtures

    test "non-force request skips duplicate successful deployment", %{organization: _org} do
      garden = garden_fixture()
      _seed = seed_fixture(%{name: "retry-host", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "retry-host",
          seed_type: "nixos"
        })

      {:ok, first_request} =
        SowerClient.Orchestration.DeploymentRequest.new(%{
          subscription_sids: [subscription.sid]
        })

      assert {:ok, first_deployment} = Orchestration.request_deployment(first_request)
      assert first_deployment.skipped == false

      {:ok, second_request} =
        SowerClient.Orchestration.DeploymentRequest.new(%{
          subscription_sids: [subscription.sid]
        })

      assert {:ok, second_deployment} = Orchestration.request_deployment(second_request)
      assert second_deployment.skipped == true
      assert second_deployment.sid == first_deployment.sid
    end

    test "force request creates new deployment even when duplicate successful deployment exists",
         %{
           organization: _org
         } do
      garden = garden_fixture()
      _seed = seed_fixture(%{name: "retry-host", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "retry-host",
          seed_type: "nixos"
        })

      {:ok, first_request} =
        SowerClient.Orchestration.DeploymentRequest.new(%{
          subscription_sids: [subscription.sid]
        })

      assert {:ok, first_deployment} = Orchestration.request_deployment(first_request)
      assert first_deployment.skipped == false

      {:ok, second_request} =
        SowerClient.Orchestration.DeploymentRequest.new(%{
          subscription_sids: [subscription.sid],
          force: true
        })

      assert {:ok, second_deployment} = Orchestration.request_deployment(second_request)
      assert second_deployment.skipped == false
      assert second_deployment.sid != first_deployment.sid
    end
  end

  describe "retry_deployment/2" do
    import Sower.OrchestrationFixtures

    test "creates retry deployment for successful deployment", %{organization: org} do
      user = user_fixture(%{org_id: org.org_id})
      garden = garden_fixture()
      seed = seed_fixture()

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: :success,
          deployed_at: DateTime.utc_now()
        })

      assert {:ok, retried} = Orchestration.retry_deployment(deployment, user.id)
      assert retried.parent_deployment_id == deployment.id
      assert retried.retried_by_user_id == user.id
      assert retried.retry_ordinal == 1

      retried = Sower.Repo.preload(retried, [:seeds, :subscriptions])
      assert Enum.map(retried.seeds, & &1.id) == [seed.id]
      assert Enum.map(retried.subscriptions, & &1.id) == [subscription.id]
    end

    test "creates retry deployment for failed deployment", %{organization: org} do
      user = user_fixture(%{org_id: org.org_id})
      garden = garden_fixture()

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          result: :failure,
          deployed_at: DateTime.utc_now()
        })

      assert {:ok, retried} = Orchestration.retry_deployment(deployment, user.id)
      assert retried.parent_deployment_id == deployment.id
    end

    test "rejects retries for non-terminal deployment", %{organization: org} do
      user = user_fixture(%{org_id: org.org_id})
      garden = garden_fixture()

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          result: nil,
          deployed_at: nil
        })

      assert {:error, :deployment_not_retryable} =
               Orchestration.retry_deployment(deployment, user.id)
    end

    test "rejects retries from user in another organization" do
      owner_user = user_fixture()
      owner_org_id = owner_user.org_id
      Sower.Repo.put_org_id(owner_org_id)

      garden = garden_fixture()

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          result: :success,
          deployed_at: DateTime.utc_now()
        })

      outsider = user_fixture()
      Sower.Repo.put_org_id(owner_org_id)

      assert {:error, :unauthorized} = Orchestration.retry_deployment(deployment, outsider.id)
    end

    test "blocks concurrent duplicate retries while retry is in progress", %{organization: org} do
      user = user_fixture(%{org_id: org.org_id})
      garden = garden_fixture()

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          result: :success,
          deployed_at: DateTime.utc_now()
        })

      assert {:ok, _retried} = Orchestration.retry_deployment(deployment, user.id)
      assert {:error, :retry_in_progress} = Orchestration.retry_deployment(deployment, user.id)
    end

    test "broadcasts deployment event to agent topic when retry is created", %{organization: org} do
      user = user_fixture(%{org_id: org.org_id})
      garden = garden_fixture()
      seed = seed_fixture(%{name: "kale", seed_type: "home-manager"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription],
          result: :success,
          deployed_at: DateTime.utc_now()
        })

      Phoenix.PubSub.subscribe(Sower.PubSub, "garden:#{garden.sid}")

      assert {:ok, retried} = Orchestration.retry_deployment(deployment, user.id)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: "deployment",
        payload: payload
      }

      assert topic == "garden:#{garden.sid}"
      assert payload.sid == retried.sid
      assert payload.skipped == false
      assert is_binary(payload.request_id)
      assert Enum.any?(payload.seed_deployments, &(&1.seed.sid == seed.sid))
    end
  end

  defp unique_hash do
    :crypto.strong_rand_bytes(16) |> Base.encode32(case: :lower) |> String.slice(0, 32)
  end

  defp garden_seed_generation_sequence_last_value do
    %Postgrex.Result{rows: [[last_value]]} =
      Ecto.Adapters.SQL.query!(
        Sower.Repo,
        "SELECT last_value FROM public.agent_seed_generations_id_seq",
        []
      )

    last_value
  end
end
