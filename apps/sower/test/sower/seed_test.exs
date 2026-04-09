defmodule Sower.SeedTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Sower.Orchestration.Seed

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "latest/1" do
    test "does not return the seed if name does not exist" do
      refute Seed.latest("unknown", "nixos")
    end

    test "returns the seed if name exists" do
      %{id: id} = seed = seed_fixture()

      assert %Seed{id: ^id} = Seed.latest(seed.name, "nixos")
    end
  end

  describe "create/1" do
    test "creates the seed if it does not exist" do
      name = unique_seed_name()

      refute Seed.latest(name, "nixos")

      %{id: id} = seed = seed_fixture(%{name: name})
      assert %Seed{id: ^id} = Seed.latest(seed.name, "nixos")
    end

    @tag :capture_log
    test "upserts" do
      seed = seed_fixture()

      {:ok, _} = Seed.create(Map.from_struct(seed))

      assert Repo.all(Sower.Orchestration.Seed) |> Enum.count() == 1
    end
  end

  describe "latest/3 with tag filtering" do
    test "returns nil when no seed matches the tags" do
      seed_fixture(%{tags: [%{key: "env", value: "prod"}]})

      refute Seed.latest("unknown", "nixos", [%{key: "env", value: "prod"}])
    end

    test "returns nil when seed exists but tags don't match" do
      name = unique_seed_name()
      seed_fixture(%{name: name, tags: [%{key: "env", value: "prod"}]})

      refute Seed.latest(name, "nixos", [%{key: "env", value: "staging"}])
    end

    test "returns the seed when all tags match" do
      name = unique_seed_name()
      %{id: id} = seed_fixture(%{name: name, tags: [%{key: "env", value: "prod"}]})

      assert %Seed{id: ^id} = Seed.latest(name, "nixos", [%{key: "env", value: "prod"}])
    end

    test "returns the seed when multiple tags all match" do
      name = unique_seed_name()

      %{id: id} =
        seed_fixture(%{
          name: name,
          tags: [
            %{key: "env", value: "prod"},
            %{key: "git_branch", value: "main"}
          ]
        })

      assert %Seed{id: ^id} =
               Seed.latest(name, "nixos", [
                 %{key: "env", value: "prod"},
                 %{key: "git_branch", value: "main"}
               ])
    end

    test "returns nil when only some tags match" do
      name = unique_seed_name()

      seed_fixture(%{
        name: name,
        tags: [
          %{key: "env", value: "prod"}
        ]
      })

      refute Seed.latest(name, "nixos", [
               %{key: "env", value: "prod"},
               %{key: "git_branch", value: "main"}
             ])
    end

    test "returns the seed when querying with subset of tags" do
      name = unique_seed_name()

      %{id: id} =
        seed_fixture(%{
          name: name,
          tags: [
            %{key: "env", value: "prod"},
            %{key: "git_branch", value: "main"}
          ]
        })

      # Seed has more tags than we query for - should still match
      assert %Seed{id: ^id} = Seed.latest(name, "nixos", [%{key: "env", value: "prod"}])
    end

    test "returns latest seed when multiple seeds match tags" do
      name = unique_seed_name()
      tags = [%{key: "env", value: "prod"}]

      # Create first seed
      seed_fixture(%{name: name, tags: tags})

      # Create second seed with same name and tags but different artifact
      %{id: latest_id} = seed_fixture(%{name: name, tags: tags})

      assert %Seed{id: ^latest_id} = Seed.latest(name, "nixos", tags)
    end

    test "delegates to latest/2 when tags list is empty" do
      name = unique_seed_name()
      %{id: id} = seed_fixture(%{name: name})

      assert %Seed{id: ^id} = Seed.latest(name, "nixos", [])
    end
  end

  describe "list_flop/1" do
    test "returns seeds with default ordering" do
      seed_a = seed_fixture(%{name: "alpha"})
      seed_b = seed_fixture(%{name: "bravo"})

      assert {:ok, {seeds, meta}} = Seed.list_flop()
      sids = Enum.map(seeds, & &1.sid)

      # Default order is updated_at desc, so most recent first
      assert seed_b.sid in sids
      assert seed_a.sid in sids
      assert meta.total_count == 2
    end

    test "filters by name with ilike_and" do
      seed_fixture(%{name: "kale-host"})
      seed_fixture(%{name: "bravo-host"})

      params = %{
        "filters" => [%{"field" => "name", "op" => "ilike_and", "value" => "kale"}]
      }

      assert {:ok, {seeds, meta}} = Seed.list_flop(params)
      assert length(seeds) == 1
      assert hd(seeds).name == "kale-host"
      assert meta.total_count == 1
    end

    test "filters by seed_type" do
      seed_fixture(%{name: "host-a", seed_type: "nixos"})
      seed_fixture(%{name: "user-a", seed_type: "home-manager"})

      params = %{
        "filters" => [%{"field" => "seed_type", "op" => "==", "value" => "nixos"}]
      }

      assert {:ok, {seeds, _meta}} = Seed.list_flop(params)
      assert Enum.all?(seeds, &(&1.seed_type == "nixos"))
    end

    test "combines multiple filters" do
      seed_fixture(%{name: "kale", seed_type: "nixos"})
      seed_fixture(%{name: "kale-hm", seed_type: "home-manager"})
      seed_fixture(%{name: "bravo", seed_type: "nixos"})

      params = %{
        "filters" => [
          %{"field" => "name", "op" => "ilike_and", "value" => "kale"},
          %{"field" => "seed_type", "op" => "==", "value" => "nixos"}
        ]
      }

      assert {:ok, {seeds, meta}} = Seed.list_flop(params)
      assert length(seeds) == 1
      assert hd(seeds).name == "kale"
      assert meta.total_count == 1
    end

    test "sorts by name ascending" do
      seed_fixture(%{name: "charlie"})
      seed_fixture(%{name: "alpha"})
      seed_fixture(%{name: "bravo"})

      params = %{"order_by" => ["name"], "order_directions" => ["asc"]}

      assert {:ok, {seeds, _meta}} = Seed.list_flop(params)
      names = Enum.map(seeds, & &1.name)
      assert names == ["alpha", "bravo", "charlie"]
    end

    test "paginates results" do
      for i <- 1..5, do: seed_fixture(%{name: "seed-#{i}"})

      params = %{"page" => 1, "page_size" => 2}
      assert {:ok, {seeds, meta}} = Seed.list_flop(params)
      assert length(seeds) == 2
      assert meta.total_count == 5
      assert meta.total_pages == 3

      params = %{"page" => 3, "page_size" => 2}
      assert {:ok, {seeds, _meta}} = Seed.list_flop(params)
      assert length(seeds) == 1
    end

    test "preloads tags" do
      seed_fixture(%{tags: [%{key: "env", value: "prod"}]})

      assert {:ok, {[seed], _meta}} = Seed.list_flop()
      assert [%{key: "env", value: "prod"}] = seed.tags
    end
  end

  describe "extract_info_from_store_path/1" do
    test "extracts the derivation name from a NixOS store path" do
      assert Seed.extract_info_from_store_path("/nix/store/abc123def-nixos-system-myhost-25.11") ==
               {"myhost", [%{key: "nixos_version", value: "25.11"}]}
    end

    test "extracts name from home-manager store path" do
      assert Seed.extract_info_from_store_path("/nix/store/xyz789abc-home-manager-generation") ==
               {"home-manager-generation", []}
    end

    test "handles paths with only hash prefix" do
      assert Seed.extract_info_from_store_path("/nix/store/abc123-simple") == {"simple", []}
    end
  end

  describe "seed_type_from_profile_path/1" do
    test "returns nixos for system profile path" do
      assert Seed.seed_type_from_profile_path("/nix/var/nix/profiles/system") == "nixos"
    end

    test "returns home-manager for home-manager profile path" do
      assert Seed.seed_type_from_profile_path("/home/user/.local/state/nix/profiles/home-manager") ==
               "home-manager"
    end

    test "returns nix-darwin for nix-darwin profile path" do
      assert Seed.seed_type_from_profile_path("/nix/var/nix/profiles/nix-darwin") == "nix-darwin"
    end

    test "defaults to nixos for unknown profile paths" do
      assert Seed.seed_type_from_profile_path("/some/unknown/path") == "nixos"
    end
  end

  describe "find_or_register/3" do
    test "returns existing seed when artifact already exists" do
      existing = seed_fixture()
      garden = garden_fixture()

      generation = %SowerClient.Orchestration.GardenSeedGeneration{
        path: existing.artifact,
        link: "/nix/var/nix/profiles/system-1-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 1,
        is_current: true
      }

      profile = %SowerClient.Orchestration.GardenSeedProfile{
        profile_path: "/nix/var/nix/profiles/system",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(garden, generation, profile)
      assert seed.id == existing.id
    end

    test "creates new seed when artifact is unknown" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"

      generation = %SowerClient.Orchestration.GardenSeedGeneration{
        path: artifact,
        link: "/nix/var/nix/profiles/system-42-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 42,
        is_current: true
      }

      profile = %SowerClient.Orchestration.GardenSeedProfile{
        profile_path: "/nix/var/nix/profiles/system",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(garden, generation, profile)
      assert seed.artifact == artifact
      assert seed.name == "testhost"
      assert seed.seed_type == "nixos"
    end

    test "adds garden_source tag when auto-registering" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"

      generation = %SowerClient.Orchestration.GardenSeedGeneration{
        path: artifact,
        link: "/nix/var/nix/profiles/system-42-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 42,
        is_current: true
      }

      profile = %SowerClient.Orchestration.GardenSeedProfile{
        profile_path: "/nix/var/nix/profiles/system",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(garden, generation, profile)

      assert Enum.any?(seed.tags, fn tag ->
               tag.key == "garden_source" && tag.value == garden.sid
             end)
    end

    test "includes profile tags when auto-registering" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-home-manager-generation"

      generation = %SowerClient.Orchestration.GardenSeedGeneration{
        path: artifact,
        link: "/home/alice/.local/state/nix/profiles/home-manager-5-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 5,
        is_current: true
      }

      profile = %SowerClient.Orchestration.GardenSeedProfile{
        profile_path: "/home/alice/.local/state/nix/profiles/home-manager",
        tags: [{"user", "alice"}],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(garden, generation, profile)
      assert seed.seed_type == "home-manager"
      assert Enum.any?(seed.tags, fn tag -> tag.key == "user" && tag.value == "alice" end)
      assert Enum.any?(seed.tags, fn tag -> tag.key == "garden_source" end)
    end

    test "determines seed_type from home-manager profile path" do
      garden = garden_fixture()
      artifact = "/nix/store/#{unique_hash()}-home-manager-generation"

      generation = %SowerClient.Orchestration.GardenSeedGeneration{
        path: artifact,
        link: "/home/alice/.local/state/nix/profiles/home-manager-5-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 5,
        is_current: true
      }

      profile = %SowerClient.Orchestration.GardenSeedProfile{
        profile_path: "/home/alice/.local/state/nix/profiles/home-manager",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(garden, generation, profile)
      assert seed.seed_type == "home-manager"
    end
  end

  defp unique_hash do
    :crypto.strong_rand_bytes(16) |> Base.encode32(case: :lower) |> String.slice(0, 32)
  end
end
