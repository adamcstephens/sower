defmodule Sower.SeedTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Sower.Seed

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

    test "upserts" do
      seed = seed_fixture()

      {:ok, _} = Seed.create(Map.from_struct(seed))

      assert Repo.all(Sower.Seed) |> Enum.count() == 1
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
      agent = agent_fixture()

      generation = %SowerClient.Orchestration.AgentSeedGeneration{
        path: existing.artifact,
        link: "/nix/var/nix/profiles/system-1-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 1,
        is_current: true
      }

      profile = %SowerClient.Orchestration.AgentSeedProfile{
        profile_path: "/nix/var/nix/profiles/system",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(agent, generation, profile)
      assert seed.id == existing.id
    end

    test "creates new seed when artifact is unknown" do
      agent = agent_fixture()
      artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"

      generation = %SowerClient.Orchestration.AgentSeedGeneration{
        path: artifact,
        link: "/nix/var/nix/profiles/system-42-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 42,
        is_current: true
      }

      profile = %SowerClient.Orchestration.AgentSeedProfile{
        profile_path: "/nix/var/nix/profiles/system",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(agent, generation, profile)
      assert seed.artifact == artifact
      assert seed.name == "testhost"
      assert seed.seed_type == "nixos"
    end

    test "adds agent_source tag when auto-registering" do
      agent = agent_fixture()
      artifact = "/nix/store/#{unique_hash()}-nixos-system-testhost-25.11"

      generation = %SowerClient.Orchestration.AgentSeedGeneration{
        path: artifact,
        link: "/nix/var/nix/profiles/system-42-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 42,
        is_current: true
      }

      profile = %SowerClient.Orchestration.AgentSeedProfile{
        profile_path: "/nix/var/nix/profiles/system",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(agent, generation, profile)

      assert Enum.any?(seed.tags, fn tag ->
               tag.key == "agent_source" && tag.value == agent.sid
             end)
    end

    test "includes profile tags when auto-registering" do
      agent = agent_fixture()
      artifact = "/nix/store/#{unique_hash()}-home-manager-generation"

      generation = %SowerClient.Orchestration.AgentSeedGeneration{
        path: artifact,
        link: "/home/alice/.local/state/nix/profiles/home-manager-5-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 5,
        is_current: true
      }

      profile = %SowerClient.Orchestration.AgentSeedProfile{
        profile_path: "/home/alice/.local/state/nix/profiles/home-manager",
        tags: [{"user", "alice"}],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(agent, generation, profile)
      assert seed.seed_type == "home-manager"
      assert Enum.any?(seed.tags, fn tag -> tag.key == "user" && tag.value == "alice" end)
      assert Enum.any?(seed.tags, fn tag -> tag.key == "agent_source" end)
    end

    test "determines seed_type from home-manager profile path" do
      agent = agent_fixture()
      artifact = "/nix/store/#{unique_hash()}-home-manager-generation"

      generation = %SowerClient.Orchestration.AgentSeedGeneration{
        path: artifact,
        link: "/home/alice/.local/state/nix/profiles/home-manager-5-link",
        created: DateTime.to_iso8601(DateTime.utc_now()),
        generation_number: 5,
        is_current: true
      }

      profile = %SowerClient.Orchestration.AgentSeedProfile{
        profile_path: "/home/alice/.local/state/nix/profiles/home-manager",
        tags: [],
        generations: [generation]
      }

      assert {:ok, seed} = Seed.find_or_register(agent, generation, profile)
      assert seed.seed_type == "home-manager"
    end
  end

  defp unique_hash do
    :crypto.strong_rand_bytes(16) |> Base.encode32(case: :lower) |> String.slice(0, 32)
  end
end
