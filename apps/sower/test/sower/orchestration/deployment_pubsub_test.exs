defmodule Sower.Orchestration.DeploymentPubSubTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.DeploymentPubSub

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)

    %{organization: org}
  end

  test "broadcast_deployment_change/2 publishes per-deployment topic", %{organization: org} do
    agent = agent_fixture(%{org_id: org.org_id})
    seed = seed_fixture(%{org_id: org.org_id, name: "seed", seed_type: "nixos"})

    subscription =
      subscription_fixture(%{
        agent_id: agent.id,
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    deployment =
      deployment_fixture(%{
        org_id: org.org_id,
        agent_id: agent.id,
        seeds: [seed],
        subscriptions: [subscription]
      })

    Phoenix.PubSub.subscribe(Sower.PubSub, "deployments")
    Phoenix.PubSub.subscribe(Sower.PubSub, "deployment:#{deployment.sid}")
    Phoenix.PubSub.subscribe(Sower.PubSub, "deployments:agent:#{agent.sid}")
    Phoenix.PubSub.subscribe(Sower.PubSub, "deployments:subscription:#{subscription.sid}")

    assert {:ok, _deployment} = DeploymentPubSub.broadcast_deployment_change(deployment, :updated)

    deployment_sid = deployment.sid

    Enum.each(1..4, fn _ ->
      assert_receive {:deployment, :updated, %{sid: ^deployment_sid}}
    end)
  end
end
