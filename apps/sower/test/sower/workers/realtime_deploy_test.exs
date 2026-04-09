defmodule Sower.Workers.RealtimeDeployTest do
  use Sower.DataCase

  use Oban.Testing, repo: Sower.Repo

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Sower.Workers.{DeploySubscription, RealtimeDeploy}

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    %{org: org}
  end

  describe "perform/1" do
    test "enqueues deploy jobs for realtime subscriptions", %{org: org} do
      garden = garden_fixture()

      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos"
        })

      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "myhost",
        seed_type: "nixos",
        allow_realtime: true
      })

      assert :ok =
               perform_job(RealtimeDeploy, %{
                 seed_id: seed.id,
                 org_id: org.org_id
               })

      assert_enqueued(worker: DeploySubscription)
    end

    test "does not enqueue jobs when no realtime subscriptions exist", %{org: org} do
      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos"
        })

      assert :ok =
               perform_job(RealtimeDeploy, %{
                 seed_id: seed.id,
                 org_id: org.org_id
               })

      refute_enqueued(worker: DeploySubscription)
    end

    test "skips subscriptions with allow_realtime false", %{org: org} do
      garden = garden_fixture()

      seed =
        seed_fixture(%{
          name: "myhost",
          seed_type: "nixos"
        })

      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "myhost",
        seed_type: "nixos",
        allow_realtime: false
      })

      assert :ok =
               perform_job(RealtimeDeploy, %{
                 seed_id: seed.id,
                 org_id: org.org_id
               })

      refute_enqueued(worker: DeploySubscription)
    end
  end
end
