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

  describe "agents" do
    alias Sower.Orchestration.Agent

    import Sower.OrchestrationFixtures

    @invalid_attrs %{name: nil}

    test "list_agents/0 returns all agents" do
      agent = agent_fixture()
      assert Orchestration.list_agents() == [agent]
    end

    test "get_agent!/1 returns the agent with given id" do
      agent = agent_fixture()
      assert Orchestration.get_agent!(agent.id) == agent
    end

    test "create_agent/1 with valid data creates a agent" do
      valid_attrs = %{name: "some agent", local_sid: "some local_sid"}

      assert {:ok, %Agent{} = agent} = Orchestration.create_agent(valid_attrs)
      assert agent.name == "some agent"
      assert agent.local_sid == "some local_sid"
    end

    test "create_agent/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Orchestration.create_agent(@invalid_attrs)
    end

    test "update_agent/2 with valid data updates the agent" do
      agent = agent_fixture()
      update_attrs = %{local_sid: "some updated local_sid"}

      assert {:ok, %Agent{} = agent} = Orchestration.update_agent(agent, update_attrs)
      assert agent.local_sid == "some updated local_sid"
    end

    test "update_agent/2 with invalid data returns error changeset" do
      agent = agent_fixture()
      assert {:error, %Ecto.Changeset{}} = Orchestration.update_agent(agent, @invalid_attrs)
      assert agent == Orchestration.get_agent!(agent.id)
    end

    test "delete_agent/1 deletes the agent" do
      agent = agent_fixture()
      assert {:ok, %Agent{}} = Orchestration.delete_agent(agent)
      assert_raise Ecto.NoResultsError, fn -> Orchestration.get_agent!(agent.id) end
    end

    test "change_agent/1 returns a agent changeset" do
      agent = agent_fixture()
      assert %Ecto.Changeset{} = Orchestration.change_agent(agent)
    end
  end

  describe "subscriptions" do
    import Sower.OrchestrationFixtures

    test "create_subscription/1 updates rules on conflict" do
      agent = agent_fixture()

      # Create initial subscription with rules
      {:ok, sub1} =
        Orchestration.create_subscription(%{
          agent_id: agent.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: "eq", value: "main"}]
        })

      assert length(sub1.rules) == 1
      assert hd(sub1.rules).value == "main"

      # Re-create with different rules (same agent, seed_name, seed_type)
      {:ok, sub2} =
        Orchestration.create_subscription(%{
          agent_id: agent.id,
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
      agent = agent_fixture()

      subscription =
        subscription_fixture(%{
          agent_id: agent.id,
          seed_name: "nonexistent",
          seed_type: "nixos"
        })

      assert Orchestration.match_seed(subscription) == nil
    end

    test "returns seed when name and type match with no rules" do
      agent = agent_fixture()
      seed = seed_fixture(%{name: "myhost", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          agent_id: agent.id,
          seed_name: "myhost",
          seed_type: "nixos"
        })

      matched = Orchestration.match_seed(subscription)
      assert matched.id == seed.id
    end

    test "returns seed when single rule matches" do
      agent = agent_fixture()

      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos",
          tags: [%{key: "branch", value: "main"}]
        })

      subscription =
        subscription_fixture(%{
          agent_id: agent.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: :eq, value: "main"}]
        })

      matched = Orchestration.match_seed(subscription)
      assert matched.id == seed.id
    end

    test "returns seed when all rules match" do
      agent = agent_fixture()

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
          agent_id: agent.id,
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
      agent = agent_fixture()

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
          agent_id: agent.id,
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
      agent = agent_fixture()

      seed_fixture(%{
        name: "myhost",
        seed_type: "nixos",
        tags: [%{key: "branch", value: "dev"}]
      })

      subscription =
        subscription_fixture(%{
          agent_id: agent.id,
          seed_name: "myhost",
          seed_type: "nixos",
          rules: [%{key: "branch", op: :eq, value: "main"}]
        })

      assert Orchestration.match_seed(subscription) == nil
    end

    test "returns nil when only some rules match" do
      agent = agent_fixture()

      seed_fixture(%{
        name: "myhost",
        seed_type: "nixos",
        tags: [
          %{key: "branch", value: "main"}
        ]
      })

      subscription =
        subscription_fixture(%{
          agent_id: agent.id,
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
      agent = agent_fixture()

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
          agent_id: agent.id,
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

    test "changeset/2 validates required fields" do
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

  describe "agent_seed_profiles" do
    alias Sower.Orchestration.{AgentSeedProfile, NixProfile}

    import Sower.OrchestrationFixtures

    test "changeset/2 validates required fields" do
      changeset = AgentSeedProfile.changeset(%AgentSeedProfile{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.org_id
      assert "can't be blank" in errors.agent_id
      assert "can't be blank" in errors.seed_id
      assert "can't be blank" in errors.profile_id
      assert "can't be blank" in errors.created_at_generation
    end

    test "changeset/2 accepts valid attributes" do
      agent = agent_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()

      changeset =
        AgentSeedProfile.changeset(%AgentSeedProfile{}, %{
          org_id: Sower.Repo.get_org_id(),
          agent_id: agent.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 42,
          is_current: true,
          created_at_generation: DateTime.utc_now()
        })

      assert changeset.valid?
    end

    test "list_for_agent/1 returns all profiles for agent ordered by generation_number desc" do
      agent = agent_fixture()
      seed1 = seed_fixture()
      seed2 = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      asp1 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed1.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: false,
          created_at_generation: now
        })

      asp2 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed2.id,
          profile_id: profile.id,
          generation_number: 2,
          is_current: true,
          created_at_generation: now
        })

      result = AgentSeedProfile.list_for_agent(agent.id)

      assert length(result) == 2
      assert Enum.at(result, 0).id == asp2.id
      assert Enum.at(result, 1).id == asp1.id
    end

    test "list_current_for_agent/1 returns only current profiles" do
      agent = agent_fixture()
      seed1 = seed_fixture()
      seed2 = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      _asp1 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed1.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: false,
          created_at_generation: now
        })

      asp2 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed2.id,
          profile_id: profile.id,
          generation_number: 2,
          is_current: true,
          created_at_generation: now
        })

      result = AgentSeedProfile.list_current_for_agent(agent.id)

      assert length(result) == 1
      assert hd(result).id == asp2.id
    end

    test "list_for_agent_profile/2 returns profiles for specific agent and profile" do
      agent = agent_fixture()
      seed1 = seed_fixture()
      seed2 = seed_fixture()
      profile1 = nix_profile_fixture(%{profile_path: "/nix/var/nix/profiles/system"})
      profile2 = nix_profile_fixture(%{profile_path: "~/.local/state/nix/profiles/home-manager"})
      now = DateTime.utc_now()

      asp1 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed1.id,
          profile_id: profile1.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      _asp2 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed2.id,
          profile_id: profile2.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      result = AgentSeedProfile.list_for_agent_profile(agent.id, profile1.id)

      assert length(result) == 1
      assert hd(result).id == asp1.id
    end

    test "upsert_from_report/4 inserts new profile" do
      agent = agent_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      attrs = %{
        generation_number: 42,
        is_current: true,
        created_at_generation: now
      }

      assert {:ok, asp} =
               AgentSeedProfile.upsert_from_report(agent.id, profile.id, seed.id, attrs)

      assert asp.generation_number == 42
      assert asp.is_current == true
    end

    test "upsert_from_report/4 updates existing profile on conflict" do
      agent = agent_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      attrs1 = %{
        generation_number: 41,
        is_current: false,
        created_at_generation: now
      }

      {:ok, asp1} = AgentSeedProfile.upsert_from_report(agent.id, profile.id, seed.id, attrs1)
      assert asp1.generation_number == 41

      attrs2 = %{
        generation_number: 42,
        is_current: true,
        created_at_generation: now
      }

      {:ok, asp2} = AgentSeedProfile.upsert_from_report(agent.id, profile.id, seed.id, attrs2)
      assert asp2.id == asp1.id
      assert asp2.generation_number == 42
      assert asp2.is_current == true
    end

    test "unique constraint on agent_id and seed_id" do
      agent = agent_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      _asp1 =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      # Attempting to insert a duplicate should fail
      result =
        %AgentSeedProfile{}
        |> AgentSeedProfile.changeset(%{
          org_id: Sower.Repo.get_org_id(),
          agent_id: agent.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 2,
          is_current: true,
          created_at_generation: now
        })
        |> Sower.Repo.insert()

      assert {:error, changeset} = result
      assert "has already been taken" in errors_on(changeset).agent_id
    end

    test "deleting agent cascades to agent_seed_profiles" do
      agent = agent_fixture()
      seed = seed_fixture()
      profile = nix_profile_fixture()
      now = DateTime.utc_now()

      asp =
        agent_seed_profile_fixture(%{
          agent_id: agent.id,
          seed_id: seed.id,
          profile_id: profile.id,
          generation_number: 1,
          is_current: true,
          created_at_generation: now
        })

      {:ok, _} = Orchestration.delete_agent(agent)

      assert AgentSeedProfile.list_for_agent(agent.id) == []
      assert Sower.Repo.get(AgentSeedProfile, asp.id) == nil
    end
  end
end
