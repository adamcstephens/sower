defmodule Sower.OrchestrationTest do
  use Sower.DataCase

  alias Sower.Orchestration

  describe "agents" do
    alias Sower.Orchestration.Agent

    import Sower.OrchestrationFixtures

    @invalid_attrs %{sid: nil, remote_sid: nil}

    test "list_agents/0 returns all agents" do
      agent = agent_fixture()
      assert Orchestration.list_agents() == [agent]
    end

    test "get_agent!/1 returns the agent with given id" do
      agent = agent_fixture()
      assert Orchestration.get_agent!(agent.id) == agent
    end

    test "create_agent/1 with valid data creates a agent" do
      valid_attrs = %{sid: "some sid", remote_sid: "some remote_sid"}

      assert {:ok, %Agent{} = agent} = Orchestration.create_agent(valid_attrs)
      assert agent.sid == "some sid"
      assert agent.remote_sid == "some remote_sid"
    end

    test "create_agent/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Orchestration.create_agent(@invalid_attrs)
    end

    test "update_agent/2 with valid data updates the agent" do
      agent = agent_fixture()
      update_attrs = %{sid: "some updated sid", remote_sid: "some updated remote_sid"}

      assert {:ok, %Agent{} = agent} = Orchestration.update_agent(agent, update_attrs)
      assert agent.sid == "some updated sid"
      assert agent.remote_sid == "some updated remote_sid"
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
end
