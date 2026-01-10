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
end
