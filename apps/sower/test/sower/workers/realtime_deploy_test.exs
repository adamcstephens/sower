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
    test "enqueues deploy jobs for subscriptions with realtime policy", %{org: org} do
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
        policy: [
          %{actions: ["activate"], triggers: ["realtime"]}
        ]
      })

      assert :ok =
               perform_job(RealtimeDeploy, %{
                 seed_id: seed.id,
                 org_id: org.org_id
               })

      assert_enqueued(worker: DeploySubscription)
    end

    test "does not enqueue jobs when no subscriptions exist", %{org: org} do
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

    test "skips subscriptions without realtime in policy triggers", %{org: org} do
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
        policy: [
          %{actions: ["activate"], triggers: ["manual", "scheduled"]}
        ]
      })

      assert :ok =
               perform_job(RealtimeDeploy, %{
                 seed_id: seed.id,
                 org_id: org.org_id
               })

      refute_enqueued(worker: DeploySubscription)
    end

    test "only the newest accepted main publication schedules a main subscription" do
      garden = garden_fixture()

      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "myhost",
        seed_type: "nixos",
        rules: [%{key: "git_branch", op: "eq", value: "main"}],
        policy: [%{actions: ["activate"], triggers: ["realtime"]}]
      })

      attrs = valid_seed_attributes(%{name: "myhost"})

      source = %{
        instance: "circus",
        project: "sower",
        job: "build",
        branch: "main",
        evaluation: "new",
        build: "new",
        order: 10,
        revision: "new-revision"
      }

      assert {:ok, _} = Sower.Orchestration.Seed.publish(source, attrs)

      assert [new_job] =
               Sower.Repo.all(
                 from(j in Oban.Job, where: fragment("?->>'publication_id' IS NOT NULL", j.args))
               )

      assert :ok = perform_job(RealtimeDeploy, new_job.args)
      assert_enqueued(worker: DeploySubscription)

      older = %{source | evaluation: "old", build: "old", order: 9}

      assert {:ok, _} =
               Sower.Orchestration.Seed.publish(older, valid_seed_attributes(%{name: "myhost"}))

      assert [_] =
               Sower.Repo.all(
                 from(j in Oban.Job, where: fragment("?->>'publication_id' IS NOT NULL", j.args))
               )

      assert :ok = perform_job(RealtimeDeploy, new_job.args)

      stale_publication =
        Sower.Repo.one!(
          from(p in Sower.Orchestration.SeedPublication, where: p.evaluation == "old")
        )

      assert :ok =
               perform_job(RealtimeDeploy, %{
                 "publication_id" => stale_publication.id,
                 "org_id" => Sower.Repo.get_org_id()
               })

      assert [_] =
               Sower.Repo.all(
                 from(j in Oban.Job, where: j.worker == "Sower.Workers.DeploySubscription")
               )
    end
  end
end
