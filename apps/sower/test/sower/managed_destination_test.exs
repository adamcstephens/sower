defmodule Sower.ManagedDestinationTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  import Sower.SeedFixtures
  import Sower.OrchestrationFixtures
  alias Sower.Orchestration.{Deployment, SeedDeployment}
  alias Sower.Repo

  setup do
    org = organization_fixture()
    Repo.put_org_id(org.org_id)
    :ok
  end

  test "same artifact has independent deployment outcomes for each destination" do
    garden = garden_fixture()
    seed = seed_fixture()
    first = SowerClient.Sid.generate("sub")
    second = SowerClient.Sid.generate("sub")

    assert {:ok, deployment} =
             Deployment.create_deployment(%{
               garden_id: garden.id,
               subscriptions: [],
               seed_deployments: [
                 %SeedDeployment{
                   seed_id: seed.id,
                   subscription_sid: first,
                   profile_name: "first"
                 },
                 %SeedDeployment{
                   seed_id: seed.id,
                   subscription_sid: second,
                   profile_name: "second"
                 }
               ]
             })

    status = %SowerClient.Orchestration.SeedDeploymentStatus{
      deployment_sid: deployment.sid,
      seed_sid: seed.sid,
      subscription_sid: second,
      status: "activating"
    }

    assert {:ok, %{}} = SeedDeployment.record_seed_status(status, garden)
    rows = Repo.preload(deployment, :seed_deployments, force: true).seed_deployments
    assert Enum.find(rows, &(&1.subscription_sid == first)).state == :pending
    assert Enum.find(rows, &(&1.subscription_sid == second)).state == :activating

    assert {:error, :seed_not_in_deployment} =
             SeedDeployment.record_seed_status(%{status | subscription_sid: nil}, garden)
  end

  test "incomplete inventory cannot remove last known generations" do
    garden = garden_fixture()
    seed = seed_fixture()
    profile = nix_profile_fixture()

    assert {:ok, generation} =
             Sower.Orchestration.upsert_garden_generation(
               garden.id,
               profile.id,
               seed.id,
               %{
                 generation_number: 1,
                 is_current: true,
                 created_at_generation: DateTime.utc_now()
               }
             )

    report = %SowerClient.Orchestration.GardenSeedsReport{
      complete: false,
      failed_profile_paths: [profile.profile_path],
      profiles: [
        %SowerClient.Orchestration.GardenSeedProfile{
          profile_path: profile.profile_path,
          generations: []
        }
      ]
    }

    assert {:ok, :ok} = Sower.Orchestration.update_garden_seed_generations(report, garden)
    assert [retained] = Sower.Orchestration.list_garden_seed_generation(garden)
    assert retained.id == generation.id
  end

  test "inventory identifies generations by profile-local generation number" do
    garden = garden_fixture()
    seed = seed_fixture()
    other_profile = nix_profile_fixture(%{profile_path: "/managed/package/other/profile"})
    profile = nix_profile_fixture()

    generation = %SowerClient.Orchestration.GardenSeedGeneration{
      path: seed.artifact,
      link: profile.profile_path <> "-1-link",
      created: DateTime.to_iso8601(DateTime.utc_now()),
      generation_number: 1,
      is_current: true
    }

    observed = %SowerClient.Orchestration.GardenSeedProfile{
      profile_path: profile.profile_path,
      generations: [generation]
    }

    other_observed = %{
      observed
      | profile_path: other_profile.profile_path,
        generations: [%{generation | link: other_profile.profile_path <> "-1-link"}]
    }

    report = %SowerClient.Orchestration.GardenSeedsReport{
      complete: true,
      profiles: [observed, other_observed]
    }

    assert {:ok, :ok} = Sower.Orchestration.update_garden_seed_generations(report, garden)
    rows = Sower.Orchestration.list_garden_seed_generation(garden)
    assert length(rows) == 2
    assert Enum.all?(rows, &(&1.seed_id == seed.id and &1.generation_number == 1))
    assert MapSet.new(rows, & &1.profile_id) == MapSet.new([profile.id, other_profile.id])
  end

  test "reconnect preserves legacy subscription binding without sending managed work to old gardens" do
    garden = garden_fixture()
    seed = seed_fixture()

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        name: "legacy",
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    legacy =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [subscription],
        state: :created
      })

    {:ok, managed} =
      Deployment.create_deployment(%{
        garden_id: garden.id,
        subscriptions: [subscription],
        state: :created,
        seed_deployments: [
          %SeedDeployment{
            seed_id: seed.id,
            subscription_sid: subscription.sid,
            profile_name: "managed"
          }
        ]
      })

    SowerWeb.Endpoint.subscribe("garden:#{garden.sid}")
    Deployment.reconcile_deployments_on_connect(garden)
    assert_receive %Phoenix.Socket.Broadcast{event: "deployment", payload: payload}
    assert payload.sid == legacy.sid
    assert [destination] = payload.seed_deployments
    assert destination.subscription_sid == subscription.sid
    assert Repo.get!(Deployment, managed.id).state == :created
  end

  test "pending inventory and deduplication distinguish destinations selecting the same seed" do
    garden = garden_fixture()
    seed = seed_fixture(%{seed_type: "package"})

    {:ok, _} =
      SowerWeb.Presence.track(self(), "garden:presence", garden.sid, %{managed_profiles_v1: true})

    first =
      subscription_fixture(%{
        garden_id: garden.id,
        name: "first",
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    second =
      subscription_fixture(%{
        garden_id: garden.id,
        name: "second",
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    request = %SowerClient.Orchestration.DeploymentRequest{
      request_id: SowerClient.Sid.generate("req"),
      subscription_sids: [first.sid],
      force: false
    }

    assert Enum.map(Deployment.pending_seeds(garden), & &1.id) == [seed.id]

    assert {:ok, first_deploy} = Deployment.request_deployment(request)
    assert Enum.map(Deployment.pending_seeds(garden), & &1.id) == [seed.id]

    assert {:ok, second_deploy} =
             Deployment.request_deployment(%{
               request
               | request_id: SowerClient.Sid.generate("req"),
                 subscription_sids: [second.sid]
             })

    refute first_deploy.sid == second_deploy.sid
    refute second_deploy.skipped
    assert [%{profile_name: "first", subscription_sid: first_sid}] = first_deploy.seed_deployments
    assert first_sid == first.sid

    assert [%{profile_name: "second", subscription_sid: second_sid}] =
             second_deploy.seed_deployments

    assert second_sid == second.sid
    assert Deployment.pending_seeds(garden) == []
  end
end
