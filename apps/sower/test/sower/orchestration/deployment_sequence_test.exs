defmodule Sower.Orchestration.DeploymentSequenceTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.{Deployment, SeedDeployment}

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    garden = garden_fixture(%{org_id: org.org_id})

    seed = seed_fixture(%{org_id: org.org_id, name: "test-seed", seed_type: "nixos"})

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    deployment =
      deployment_fixture(%{
        org_id: org.org_id,
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [subscription],
        state: :dispatched,
        last_dispatched_at: DateTime.utc_now()
      })

    %{org: org, garden: garden, seed: seed, subscription: subscription, deployment: deployment}
  end

  describe "happy path: full deployment sequence" do
    test "create → dispatch → acknowledged → downloading → activating → seed success → deployment success",
         %{garden: garden, seed: seed, deployment: deployment} do
      # Verify initial state
      assert deployment.state == :dispatched

      # Step 1: Garden acknowledges deployment
      {:ok, acknowledged} =
        Deployment.record_deployment_status(%SowerClient.Orchestration.DeploymentStatus{
          deployment_sid: deployment.sid,
          status: :acknowledged
        })

      assert acknowledged.state == :acknowledged

      # Step 2: Seed starts downloading
      {:ok, _} =
        SeedDeployment.record_seed_status(
          %SowerClient.Orchestration.SeedDeploymentStatus{
            deployment_sid: deployment.sid,
            seed_sid: seed.sid,
            status: :downloading
          },
          garden
        )

      assert_seed_state(deployment, seed, :downloading)

      # Step 3: Seed starts activating
      {:ok, _} =
        SeedDeployment.record_seed_status(
          %SowerClient.Orchestration.SeedDeploymentStatus{
            deployment_sid: deployment.sid,
            seed_sid: seed.sid,
            status: :activating
          },
          garden
        )

      assert_seed_state(deployment, seed, :activating)

      # Step 4: Seed result success
      {:ok, _} =
        SeedDeployment.record_seed_result(
          %SowerClient.Orchestration.SeedDeploymentResult{
            deployment_sid: deployment.sid,
            seed_sid: seed.sid,
            result: :success,
            log: "activation complete"
          },
          garden
        )

      seed_deploy = fetch_seed_deployment(deployment, seed)
      assert seed_deploy.result == :success
      assert seed_deploy.log == "activation complete"

      # Step 5: Deployment result success
      deployed_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, completed} =
        Deployment.record_deployment(%SowerClient.Orchestration.DeploymentResult{
          request_id: SowerClient.Sid.generate("req"),
          deployment_sid: deployment.sid,
          result: :success,
          deployed_at: deployed_at
        })

      assert completed.state == :completed
      assert completed.result == :success
      assert completed.deployed_at == deployed_at
    end
  end

  describe "partial failure" do
    setup %{org: org, garden: garden, seed: first_seed} do
      second_seed =
        seed_fixture(%{org_id: org.org_id, name: "test-seed-2", seed_type: "nixos"})

      two_seed_deployment =
        deployment_fixture(%{
          org_id: org.org_id,
          garden_id: garden.id,
          seeds: [first_seed, second_seed],
          state: :dispatched,
          last_dispatched_at: DateTime.utc_now()
        })

      %{second_seed: second_seed, two_seed_deployment: two_seed_deployment}
    end

    test "one seed succeeds and one fails results in partial deployment",
         %{
           garden: garden,
           seed: first_seed,
           second_seed: second_seed,
           two_seed_deployment: deployment
         } do
      # Acknowledge
      {:ok, _} =
        Deployment.record_deployment_status(%SowerClient.Orchestration.DeploymentStatus{
          deployment_sid: deployment.sid,
          status: :acknowledged
        })

      # First seed succeeds
      {:ok, _} =
        SeedDeployment.record_seed_result(
          %SowerClient.Orchestration.SeedDeploymentResult{
            deployment_sid: deployment.sid,
            seed_sid: first_seed.sid,
            result: :success,
            log: "ok"
          },
          garden
        )

      # Second seed fails
      {:ok, _} =
        SeedDeployment.record_seed_result(
          %SowerClient.Orchestration.SeedDeploymentResult{
            deployment_sid: deployment.sid,
            seed_sid: second_seed.sid,
            result: :failure,
            log: "activation failed"
          },
          garden
        )

      # Deployment reports partial
      {:ok, completed} =
        Deployment.record_deployment(%SowerClient.Orchestration.DeploymentResult{
          request_id: SowerClient.Sid.generate("req"),
          deployment_sid: deployment.sid,
          result: :partial,
          deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert completed.state == :completed
      assert completed.result == :partial

      # Verify individual seed results
      assert fetch_seed_deployment(deployment, first_seed).result == :success
      assert fetch_seed_deployment(deployment, second_seed).result == :failure
    end
  end

  describe "stale finalization" do
    test "unresolved deployment is marked stale after timeout", %{deployment: deployment} do
      assert deployment.state == :dispatched

      # Simulate finalization by shifting "now" 3 hours into the future
      now = DateTime.add(DateTime.utc_now(), 3 * 60 * 60, :second)
      {:ok, count} = Deployment.finalize_stale_deployments(now: now)
      assert count == 1

      stale = Deployment.get_deployment!(deployment.id)
      assert stale.state == :stale
      assert stale.result == :failure
      assert stale.deployed_at != nil
    end
  end

  describe "seed log accumulation" do
    test "multiple seed results append logs", %{
      garden: garden,
      seed: seed,
      deployment: deployment
    } do
      # First result with log but no result (progress update)
      {:ok, _} =
        SeedDeployment.record_seed_result(
          %SowerClient.Orchestration.SeedDeploymentResult{
            deployment_sid: deployment.sid,
            seed_sid: seed.sid,
            log: "downloading store paths"
          },
          garden
        )

      sd = fetch_seed_deployment(deployment, seed)
      assert sd.log == "downloading store paths"
      assert sd.result == nil

      # Second result with log and final result
      {:ok, _} =
        SeedDeployment.record_seed_result(
          %SowerClient.Orchestration.SeedDeploymentResult{
            deployment_sid: deployment.sid,
            seed_sid: seed.sid,
            result: :success,
            log: "activation complete"
          },
          garden
        )

      sd = fetch_seed_deployment(deployment, seed)
      assert sd.log == "downloading store paths\nactivation complete"
      assert sd.result == :success
    end
  end

  defp assert_seed_state(deployment, seed, expected_state) do
    sd = fetch_seed_deployment(deployment, seed)
    assert sd.state == expected_state
  end

  defp fetch_seed_deployment(deployment, seed) do
    Repo.one!(
      from(sd in SeedDeployment,
        join: s in assoc(sd, :seed),
        where: sd.deployment_id == ^deployment.id and s.sid == ^seed.sid
      ),
      skip_org_id: true
    )
  end
end
