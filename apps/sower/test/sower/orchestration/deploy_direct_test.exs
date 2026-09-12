defmodule Sower.Orchestration.DeployDirectTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.{Deployment, DeploymentEvent, Garden}

  import Ecto.Query
  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  @direct_policy [%{name: "direct", actions: ["activate"], triggers: ["direct"]}]

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    garden = garden_fixture(%{org_id: org.org_id})
    seed = seed_fixture(%{org_id: org.org_id, name: "direct-host", seed_type: "nixos"})

    %{org: org, garden: garden, seed: seed}
  end

  defp with_policy(%Garden{} = garden, policy) do
    {:ok, garden} = Garden.update_garden(garden, %{policy: policy})
    garden
  end

  defp events(%Deployment{} = deployment) do
    Repo.all(from(e in DeploymentEvent, where: e.deployment_id == ^deployment.id))
  end

  describe "policy path" do
    test "denies when the garden declares no policy", %{garden: garden, seed: seed} do
      assert {:error, :policy_denied} = Deployment.deploy_direct(garden, seed)
    end

    test "denies when the garden policy omits the direct trigger", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [%{name: "manual", actions: ["activate"], triggers: ["manual"]}])

      assert {:error, :policy_denied} = Deployment.deploy_direct(garden, seed)
    end

    test "allows when the garden policy permits direct", %{garden: garden, seed: seed} do
      garden = with_policy(garden, @direct_policy)

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed, actor_sid: "tok_1")
      refute dispatched.skipped
      assert [%{seed: ^seed, action: "activate"}] = dispatched.seed_deployments

      deployment = Deployment.get_deployment_sid!(dispatched.sid)
      assert [event] = events(deployment)
      assert event.reason == :direct_triggered
      assert event.actor_sid == "tok_1"
      assert is_nil(event.note)
    end

    test "defaults to activate when all direct actions are permitted", %{
      garden: garden,
      seed: seed
    } do
      garden =
        with_policy(garden, [
          %{name: "direct", actions: ["stage", "activate", "restart"], triggers: ["direct"]}
        ])

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed)
      assert [%{action: "activate"}] = dispatched.seed_deployments
    end

    test "honors explicit stage without upgrading it", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [
          %{name: "direct", actions: ["stage", "activate", "restart"], triggers: ["direct"]}
        ])

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed, action: "stage")
      assert [%{action: "stage"}] = dispatched.seed_deployments
    end

    test "honors explicit restart without override", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [
          %{name: "direct", actions: ["activate", "restart"], triggers: ["direct"]}
        ])

      assert {:ok, dispatched} =
               Deployment.deploy_direct(garden, seed, action: "restart", actor_sid: "tok_1")

      assert [%{action: "restart"}] = dispatched.seed_deployments

      deployment = Deployment.get_deployment_sid!(dispatched.sid)
      assert [%{reason: :direct_triggered}] = events(deployment)
    end

    test "rejects a disallowed restart instead of downgrading to activate", %{
      garden: garden,
      seed: seed
    } do
      garden = with_policy(garden, @direct_policy)

      assert {:error, :policy_denied} =
               Deployment.deploy_direct(garden, seed, action: "restart")
    end

    test "rejects default activate when only restart is permitted", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [
          %{name: "direct", actions: ["restart"], triggers: ["direct"]}
        ])

      assert {:error, :policy_denied} = Deployment.deploy_direct(garden, seed, action: nil)
    end

    test "ignores confirmation required for a different action", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [
          %{name: "activate", actions: ["activate"], triggers: ["direct"]},
          %{name: "restart", actions: ["restart"], triggers: ["direct"], confirm: true}
        ])

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed, action: "activate")
      assert [%{action: "activate"}] = dispatched.seed_deployments
    end

    test "requires requested action confirmation even when another action is allowed", %{
      garden: garden,
      seed: seed
    } do
      garden =
        with_policy(garden, [
          %{name: "activate", actions: ["activate"], triggers: ["direct"], confirm: true},
          %{name: "restart", actions: ["restart"], triggers: ["direct"]}
        ])

      assert {:error, :confirmation_required} =
               Deployment.deploy_direct(garden, seed, action: "activate")
    end

    test "rejects restart outside its window even when activate is allowed", %{
      garden: garden,
      seed: seed
    } do
      garden =
        with_policy(garden, [
          %{name: "activate", actions: ["activate"], triggers: ["direct"]},
          %{
            name: "restart",
            actions: ["restart"],
            triggers: ["direct"],
            window: %{days: [], time_start: "00:00", time_end: "23:59"}
          }
        ])

      assert {:error, :policy_denied} =
               Deployment.deploy_direct(garden, seed, action: "restart")
    end

    test "rejects restart allowed only under a different trigger", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [
          %{name: "activate", actions: ["activate"], triggers: ["direct"]},
          %{name: "restart", actions: ["restart"], triggers: ["manual"]}
        ])

      assert {:error, :policy_denied} =
               Deployment.deploy_direct(garden, seed, action: "restart")
    end

    test "denies outside the policy window", %{garden: garden, seed: seed} do
      # A window that never contains "now" on the day it is evaluated is hard to
      # express, so pin the days to the one that isn't today.
      today = Date.utc_today() |> Date.day_of_week()
      other_day = Enum.at(["mon", "tue", "wed", "thu", "fri", "sat", "sun"], rem(today, 7))

      garden =
        with_policy(garden, [
          %{
            name: "window",
            actions: ["activate"],
            triggers: ["direct"],
            window: %{days: [other_day], time_start: "00:00", time_end: "23:59"}
          }
        ])

      assert {:error, :policy_denied} = Deployment.deploy_direct(garden, seed)
    end

    test "requires confirmation when the matching rule asks for it", %{garden: garden, seed: seed} do
      garden =
        with_policy(garden, [
          %{name: "direct", actions: ["activate"], triggers: ["direct"], confirm: true}
        ])

      assert {:error, :confirmation_required} = Deployment.deploy_direct(garden, seed)
    end
  end

  describe "override path" do
    test "bypasses policy with an action and a reason", %{garden: garden, seed: seed} do
      assert {:ok, dispatched} =
               Deployment.deploy_direct(garden, seed,
                 override: true,
                 action: "restart",
                 reason: "prod incident 42",
                 actor_sid: "tok_2"
               )

      assert [%{action: "restart"}] = dispatched.seed_deployments

      deployment = Deployment.get_deployment_sid!(dispatched.sid)
      assert [event] = events(deployment)
      assert event.reason == :direct_override
      assert event.note == "prod incident 42"
    end

    test "requires an action", %{garden: garden, seed: seed} do
      assert {:error, :override_action_required} =
               Deployment.deploy_direct(garden, seed, override: true, reason: "why not")
    end

    test "requires a reason", %{garden: garden, seed: seed} do
      assert {:error, :override_reason_required} =
               Deployment.deploy_direct(garden, seed, override: true, action: "activate")
    end
  end

  describe "subscription linkage and dedupe" do
    test "links a subscription matching the seed name and type", %{garden: garden, seed: seed} do
      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          name: "host",
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      garden = with_policy(garden, @direct_policy)

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed)
      assert [%{subscription_sid: sid}] = dispatched.seed_deployments
      assert sid == subscription.sid

      deployment =
        dispatched.sid |> Deployment.get_deployment_sid!() |> Repo.preload(:subscriptions)

      assert [%{id: linked_id}] = deployment.subscriptions
      assert linked_id == subscription.id
    end

    test "ignores subscription tag rules when matching", %{garden: garden, seed: seed} do
      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          name: "host",
          seed_name: seed.name,
          seed_type: seed.seed_type,
          rules: [%{key: "branch", op: "eq", value: "nope"}]
        })

      garden = with_policy(garden, @direct_policy)

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed)
      assert [%{subscription_sid: sid}] = dispatched.seed_deployments
      assert sid == subscription.sid
    end

    test "leaves the subscription unset when none matches", %{garden: garden, seed: seed} do
      garden = with_policy(garden, @direct_policy)

      assert {:ok, dispatched} = Deployment.deploy_direct(garden, seed)
      assert [%{subscription_sid: nil}] = dispatched.seed_deployments
    end

    test "skips a duplicate closure unless forced", %{garden: garden, seed: seed} do
      garden = with_policy(garden, @direct_policy)

      assert {:ok, first} = Deployment.deploy_direct(garden, seed)
      assert {:ok, second} = Deployment.deploy_direct(garden, seed)
      assert second.skipped
      assert second.sid == first.sid

      assert {:ok, third} = Deployment.deploy_direct(garden, seed, force: true)
      refute third.skipped
      assert third.sid != first.sid
    end
  end
end
