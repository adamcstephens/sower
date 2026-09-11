defmodule Sower.Orchestration.PendingDeploymentsTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.Deployment

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup do
    org = organization_fixture()
    Repo.put_org_id(org.org_id)
    %{garden: garden_fixture()}
  end

  test "returns each newest tag-matching seed once, scoped to the garden", %{garden: garden} do
    attrs = %{name: "host", tags: [%{key: "branch", value: "main"}]}
    seed_fixture(attrs)
    latest = seed_fixture(attrs)
    seed_fixture(%{name: "host", tags: [%{key: "branch", value: "dev"}]})
    seed_fixture(%{name: "host", seed_type: "home-manager", tags: attrs.tags})

    for name <- ["system", "duplicate"] do
      subscription_fixture(%{
        garden_id: garden.id,
        name: name,
        seed_name: "host",
        seed_type: "nixos",
        rules: [%{key: "branch", op: :eq, value: "main"}]
      })
    end

    subscription_fixture(%{garden_id: garden.id, seed_name: "missing", seed_type: "nixos"})
    other_garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})
    other_seed = seed_fixture(%{name: "other-host"})

    subscription_fixture(%{
      garden_id: other_garden.id,
      seed_name: other_seed.name,
      seed_type: other_seed.seed_type
    })

    assert Enum.map(Deployment.pending_seeds(garden), & &1.sid) == [latest.sid]
    assert Enum.map(Deployment.pending_seeds(other_garden), & &1.sid) == [other_seed.sid]
    assert Repo.aggregate(Deployment, :count) == 0
  end

  test "matches non-force deduplication across deployment states without changing history", %{
    garden: garden
  } do
    seed = seed_fixture()

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    request =
      SowerClient.Orchestration.DeploymentRequest.cast!(%{
        request_id: SowerClient.Sid.generate("req"),
        subscription_sids: [subscription.sid]
      })

    assert {:ok, dispatched} = Deployment.request_deployment(request)
    deployment = Deployment.get_deployment_sid!(dispatched.sid)
    other_garden = garden_fixture(%{sid: SowerClient.Sid.generate("grdn")})

    subscription_fixture(%{
      garden_id: other_garden.id,
      seed_name: seed.name,
      seed_type: seed.seed_type
    })

    assert Enum.map(Deployment.pending_seeds(other_garden), & &1.sid) == [seed.sid]

    for attrs <- [
          %{state: :created, result: nil},
          %{state: :dispatched, result: nil},
          %{state: :acknowledged, result: nil},
          %{state: :completed, result: :success}
        ] do
      {:ok, updated} = Deployment.update_deployment(deployment, attrs)
      before = Repo.get!(Deployment, updated.id)
      assert Deployment.pending_seeds(garden) == []
      assert Repo.get!(Deployment, updated.id) == before
    end

    {:ok, _failed} =
      Deployment.update_deployment(deployment, %{state: :completed, result: :failure})

    before = Repo.all(Deployment)

    assert Enum.map(Deployment.pending_seeds(garden), & &1.sid) == [seed.sid]
    assert Repo.all(Deployment) == before
  end
end
