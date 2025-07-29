defmodule Sower.OrchestrationTest do
  use Sower.DataCase

  alias Sower.Orchestration
  import Sower.AccountsFixtures

  setup _ do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  describe "agents" do
    alias Sower.Orchestration.Agent

    import Sower.OrchestrationFixtures

    @invalid_attrs %{sid: nil, local_sid: nil}

    test "list_agents/0 returns all agents" do
      agent = agent_fixture()
      assert Orchestration.list_agents() == [agent]
    end

    test "get_agent!/1 returns the agent with given id" do
      agent = agent_fixture()
      assert Orchestration.get_agent!(agent.id) == agent
    end

    test "create_agent/1 with valid data creates a agent" do
      valid_attrs = %{sid: "some sid", local_sid: "some local_sid"}

      assert {:ok, %Agent{} = agent} = Orchestration.create_agent(valid_attrs)
      assert agent.sid == "some sid"
      assert agent.local_sid == "some local_sid"
    end

    test "create_agent/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Orchestration.create_agent(@invalid_attrs)
    end

    test "update_agent/2 with valid data updates the agent" do
      agent = agent_fixture()
      update_attrs = %{sid: "some updated sid", local_sid: "some updated local_sid"}

      assert {:ok, %Agent{} = agent} = Orchestration.update_agent(agent, update_attrs)
      assert agent.sid == "some updated sid"
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
    alias Sower.Orchestration.Subscription

    import Sower.OrchestrationFixtures

    @invalid_attrs %{sid: nil}

    test "list_subscriptions/0 returns all subscriptions" do
      subscription = subscription_fixture()
      assert Orchestration.list_subscriptions() == [subscription]
    end

    test "get_subscription!/1 returns the subscription with given id" do
      subscription = subscription_fixture()
      assert Orchestration.get_subscription!(subscription.id) == subscription
    end

    test "create_subscription/1 with valid data creates a subscription" do
      valid_attrs = %{sid: "some sid"}

      assert {:ok, %Subscription{} = subscription} =
               Orchestration.create_subscription(valid_attrs)

      assert subscription.sid == "some sid"
    end

    test "create_subscription/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Orchestration.create_subscription(@invalid_attrs)
    end

    test "update_subscription/2 with valid data updates the subscription" do
      subscription = subscription_fixture()
      update_attrs = %{sid: "some updated sid"}

      assert {:ok, %Subscription{} = subscription} =
               Orchestration.update_subscription(subscription, update_attrs)

      assert subscription.sid == "some updated sid"
    end

    test "update_subscription/2 with invalid data returns error changeset" do
      subscription = subscription_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Orchestration.update_subscription(subscription, @invalid_attrs)

      assert subscription == Orchestration.get_subscription!(subscription.id)
    end

    test "delete_subscription/1 deletes the subscription" do
      subscription = subscription_fixture()
      assert {:ok, %Subscription{}} = Orchestration.delete_subscription(subscription)
      assert_raise Ecto.NoResultsError, fn -> Orchestration.get_subscription!(subscription.id) end
    end

    test "change_subscription/1 returns a subscription changeset" do
      subscription = subscription_fixture()
      assert %Ecto.Changeset{} = Orchestration.change_subscription(subscription)
    end
  end
end
