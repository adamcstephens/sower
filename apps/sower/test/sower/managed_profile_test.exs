defmodule Sower.ManagedProfileTest do
  use Sower.DataCase
  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  alias Sower.Repo
  alias Sower.Orchestration.{Garden, ManagedProfile, Subscription}
  alias SowerClient.Orchestration.{GardenSeedProfile, ProfileOperation, ProfileOperationResult}

  setup do
    org = organization_fixture()
    Repo.put_org_id(org.org_id)
    garden = garden_fixture(%{capabilities: ["managed_profiles_v1"]})

    {:ok, subscription} =
      Subscription.create_subscription(%{
        garden_id: garden.id,
        name: "tools",
        seed_name: "tools-seed",
        seed_type: "package"
      })

    profile = %GardenSeedProfile{
      name: "tools",
      managed: true,
      profile_path: "/var/lib/sower-profiles/tools/profile",
      generations: [],
      subscription_sid: subscription.sid,
      seed_type: "package"
    }

    ManagedProfile.observe(garden, [profile])
    %{garden: garden, subscription: subscription, profile: profile}
  end

  test "stage uses manual subscription policy and persists a direct-only denial", %{
    garden: garden,
    subscription: subscription
  } do
    assert {:ok, _} =
             SowerWeb.Presence.track(self(), "garden:presence", garden.sid, %{
               managed_profiles_v1: true
             })

    assert Garden.managed_profiles_supported?(garden)

    assert {:ok, subscription} =
             Subscription.update_subscription(subscription, %{
               policy: [%{name: "direct", actions: ["stage"], triggers: ["direct"]}]
             })

    operation = %ProfileOperation{
      request_id: "manual-policy-stage",
      profile_name: subscription.name,
      subscription_sid: subscription.sid,
      seed_sid: SowerClient.Sid.generate("seed"),
      action: "stage",
      preview: false
    }

    assert {:ok, %{status: "pending"}} = ManagedProfile.request(garden, operation)

    assert {:ok, %{status: "failed", error: ":policy_denied"}} =
             ManagedProfile.operation_result(garden, operation.request_id)

    assert ManagedProfile.pending(garden) == []
    assert Repo.aggregate(Sower.Orchestration.Deployment, :count) == 0
  end

  test "offline deletion retains tombstone and replays blocked intent until completed", %{
    garden: garden,
    subscription: subscription
  } do
    operation = %ProfileOperation{
      request_id: "remove-tools",
      profile_name: "tools",
      action: "uninstall",
      preview: false
    }

    assert {:ok, %{status: "pending", warning: warning}} =
             ManagedProfile.request(garden, operation)

    assert warning =~ "External services"
    assert Repo.reload!(subscription).uninstall_pending
    assert Subscription.list_subscriptions_for_garden(garden) == []
    operation = %{operation | subscription_sid: subscription.sid}
    assert [^operation] = ManagedProfile.pending(garden)

    assert {:ok, %{status: "blocked"}} =
             ManagedProfile.acknowledge(garden, %ProfileOperationResult{
               request_id: operation.request_id,
               status: "blocked",
               error: "pinned_generations"
             })

    assert ManagedProfile.get_for_garden(garden, "tools").lifecycle_status == "uninstall_blocked"
    assert [^operation] = ManagedProfile.pending(garden)
    assert Repo.reload!(subscription)

    assert {:ok, %{status: "completed"}} =
             ManagedProfile.acknowledge(garden, %ProfileOperationResult{
               request_id: operation.request_id,
               status: "completed"
             })

    assert Repo.get(Subscription, subscription.id) == nil
    assert ManagedProfile.list_for_garden(garden) == []
    assert ManagedProfile.pending(garden) == []
  end

  test "preview and missing observations never delete ownership", %{
    garden: garden,
    subscription: subscription
  } do
    assert {:ok, %{status: "preview", warning: warning}} =
             ManagedProfile.request(garden, %ProfileOperation{
               request_id: "preview",
               profile_name: "tools",
               action: "uninstall",
               preview: true
             })

    assert warning =~ "paths will disappear"
    assert not Repo.reload!(subscription).uninstall_pending
    assert {:ok, []} = Subscription.sync_subscriptions([], garden.id)
    ManagedProfile.observe(garden, [])
    assert Repo.reload!(subscription)
    assert [%{name: "tools"}] = ManagedProfile.list_for_garden(garden)
    assert ManagedProfile.pending(garden) == []
  end

  test "registration cannot resurrect a pending uninstall", %{
    garden: garden,
    subscription: subscription
  } do
    assert {:ok, _} = Subscription.delete_subscription(subscription)

    config = %SowerClient.Orchestration.Subscription{
      name: "tools",
      seed_name: "tools-seed",
      seed_type: "package",
      rules: [],
      policy: %{}
    }

    assert {:ok, []} = Subscription.sync_subscriptions([config], garden.id)
    assert Repo.reload!(subscription).uninstall_pending
    assert Subscription.find_for_garden_seed(garden, "tools-seed", "package") == nil
  end

  test "request IDs are idempotent and cannot address another action", %{garden: garden} do
    operation = %ProfileOperation{
      request_id: "same",
      profile_name: "tools",
      action: "uninstall",
      preview: false
    }

    assert {:ok, first} = ManagedProfile.request(garden, operation)
    assert {:ok, ^first} = ManagedProfile.request(garden, operation)

    assert {:error, :request_id_conflict} =
             ManagedProfile.request(garden, %{operation | action: "pin"})
  end

  test "another garden cannot acknowledge an operation", %{garden: garden} do
    operation = %ProfileOperation{
      request_id: "scoped",
      profile_name: "tools",
      action: "uninstall",
      preview: false
    }

    assert {:ok, _} = ManagedProfile.request(garden, operation)
    other = garden_fixture()

    assert {:error, :not_found} =
             ManagedProfile.acknowledge(other, %ProfileOperationResult{
               request_id: "scoped",
               status: "completed"
             })

    assert [_] = ManagedProfile.pending(garden)
  end

  test "retention accepts zero and nil but rejects empty, negative and unknown values", %{
    subscription: subscription
  } do
    for retention <- [
          nil,
          %{"keep_generations" => 0},
          %{"keep_days" => 2, "keep_generations" => 1}
        ] do
      assert {:ok, _} = Subscription.update_subscription(subscription, %{retention: retention})
    end

    for retention <- [%{}, %{"keep_days" => -1}, %{"other" => 3}] do
      assert {:error, %Ecto.Changeset{}} =
               Subscription.update_subscription(subscription, %{retention: retention})
    end
  end

  test "persisted capability does not authorize dispatch without a capable session", %{
    garden: garden
  } do
    refute Garden.managed_profiles_supported?(garden)
  end

  test "completed removal stays terminal and blocks stale declarative resurrection", %{
    garden: garden,
    subscription: subscription
  } do
    operation = %ProfileOperation{
      request_id: "terminal",
      profile_name: "tools",
      action: "uninstall",
      preview: false
    }

    assert {:ok, _} = ManagedProfile.request(garden, operation)

    assert {:ok, first} =
             ManagedProfile.request(garden, %{operation | request_id: "duplicate-delete"})

    assert first.request_id == "terminal"

    assert {:ok, %{status: "completed"}} =
             ManagedProfile.acknowledge(garden, %ProfileOperationResult{
               request_id: "terminal",
               status: "completed"
             })

    assert {:ok, %{status: "completed"}} =
             ManagedProfile.acknowledge(garden, %ProfileOperationResult{
               request_id: "terminal",
               status: "blocked",
               error: "late"
             })

    config = %SowerClient.Orchestration.Subscription{
      name: "tools",
      seed_name: "tools-seed",
      seed_type: "package",
      rules: [],
      policy: %{}
    }

    assert {:ok, []} = Subscription.sync_subscriptions([config], garden.id)
    assert ManagedProfile.list_for_garden(garden) == []

    assert {:ok, recreated} =
             Subscription.create_subscription(%{
               garden_id: garden.id,
               name: "tools",
               seed_name: "tools-seed",
               seed_type: "package"
             })

    assert recreated.sid != subscription.sid
    assert {:ok, %{status: "completed"}} = ManagedProfile.request(garden, operation)
    assert not Repo.reload!(recreated).uninstall_pending

    assert {:error, :ownership_conflict} =
             ManagedProfile.request(garden, %{
               operation
               | request_id: "old-binding",
                 subscription_sid: subscription.sid
             })
  end

  test "unknown inspection and preview fail and offline inventory exposes observation time", %{
    garden: garden
  } do
    assert {:error, :not_found} =
             ManagedProfile.request(garden, %ProfileOperation{
               request_id: "unknown",
               profile_name: "missing",
               action: "inspect"
             })

    assert {:error, :not_found} =
             ManagedProfile.request(garden, %ProfileOperation{
               request_id: "unknown-preview",
               profile_name: "missing",
               action: "uninstall",
               preview: true
             })

    profile = ManagedProfile.get_for_garden(garden, "tools")
    assert profile.stale
    assert profile.observed_at
  end

  test "completed removal deletes only the owned managed generation inventory", %{
    garden: garden,
    profile: profile
  } do
    seed = Sower.SeedFixtures.seed_fixture(%{seed_type: "package"})
    owned = Sower.Orchestration.NixProfile.find_or_create!(profile.profile_path)

    other =
      Sower.Orchestration.NixProfile.find_or_create!("/var/lib/sower-profiles/other/profile")

    rows =
      for {path, identity, managed} <- [
            {owned, "owned", true},
            {other, "other", true},
            {owned, "legacy", false}
          ] do
        %Sower.Orchestration.GardenSeedGeneration{}
        |> Sower.Orchestration.GardenSeedGeneration.changeset(%{
          org_id: garden.org_id,
          garden_id: garden.id,
          seed_id: seed.id,
          profile_id: path.id,
          generation_id: identity,
          managed: managed,
          created_at_generation: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.insert!()
      end

    assert {:ok, _} =
             ManagedProfile.request(garden, %ProfileOperation{
               request_id: "cleanup",
               profile_name: "tools",
               action: "uninstall",
               preview: false
             })

    assert {:ok, _} =
             ManagedProfile.acknowledge(garden, %ProfileOperationResult{
               request_id: "cleanup",
               status: "completed"
             })

    [owned_row, other_row, legacy_row] = rows
    assert Repo.get(Sower.Orchestration.GardenSeedGeneration, owned_row.id) == nil
    assert Repo.get(Sower.Orchestration.GardenSeedGeneration, other_row.id)
    assert Repo.get(Sower.Orchestration.GardenSeedGeneration, legacy_row.id)
    assert Repo.get(Sower.Orchestration.Seed, seed.id)
  end

  test "incomplete and failed profile observations cannot replace cached inventory", %{
    garden: garden,
    profile: profile
  } do
    socket = %Phoenix.Socket{assigns: %{garden: garden}}

    changed = %{
      "name" => "tools",
      "managed" => true,
      "profile_path" => "/wrong/path",
      "generations" => []
    }

    for payload <- [
          %{"profiles" => [changed], "complete" => false},
          %{
            "profiles" => [changed],
            "complete" => true,
            "failed_profile_paths" => ["/wrong/path"]
          }
        ] do
      assert {:reply, {:ok, _}, _} =
               SowerWeb.GardenChannel.handle_in("garden:seeds:report", payload, socket)

      assert ManagedProfile.get_for_garden(garden, "tools").profile_path == profile.profile_path
    end
  end

  test "failed generation validation rolls back profile snapshot changes", %{
    garden: garden,
    profile: profile
  } do
    socket = %Phoenix.Socket{assigns: %{garden: garden}}

    payload = %{
      "complete" => true,
      "profiles" => [
        %{
          "name" => "tools",
          "managed" => true,
          "profile_path" => "/different/path",
          "generations" => [
            %{
              "generation_id" => "missing",
              "seed_sid" => "seed_missing",
              "path" => "/nix/store/missing",
              "link" => "/different/path-1-link",
              "created" => DateTime.to_iso8601(DateTime.utc_now()),
              "is_current" => true
            }
          ]
        }
      ]
    }

    assert {:reply, {:error, _}, _} =
             SowerWeb.GardenChannel.handle_in("garden:seeds:report", payload, socket)

    assert ManagedProfile.get_for_garden(garden, "tools").profile_path == profile.profile_path
  end
end

defmodule Sower.ManagedRetentionRegistrationTest do
  use Sower.DataCase
  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  alias Sower.Orchestration.Subscription

  test "operator retention survives unchanged config and yields to changed or removed declaration" do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    garden = garden_fixture()

    config = %SowerClient.Orchestration.Subscription{
      name: "shell",
      seed_name: "shell",
      seed_type: "devshell",
      rules: [],
      policy: %{},
      retention: nil
    }

    assert {:ok, first} = Subscription.register_subscription(config, garden.id)
    subscription = Subscription.get_subscription_sid!(first.sid)
    assert subscription.retention_config_observed

    assert {:ok, _} =
             Subscription.update_subscription(subscription, %{retention: %{"keep_days" => 8}})

    assert {:ok, _} = Subscription.register_subscription(config, garden.id)
    assert Subscription.get_subscription_sid!(first.sid).retention == %{"keep_days" => 8}
    changed = %{config | retention: %{"keep_generations" => 2}}
    assert {:ok, _} = Subscription.register_subscription(changed, garden.id)
    assert Subscription.get_subscription_sid!(first.sid).retention == %{"keep_generations" => 2}
    assert {:ok, _} = Subscription.register_subscription(config, garden.id)
    assert Subscription.get_subscription_sid!(first.sid).retention == nil
  end
end

defmodule Sower.ManagedSubscriptionOriginTest do
  use Sower.DataCase
  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  alias Sower.Orchestration.Subscription

  test "operator provenance cannot be forged or replaced by configuration and survives omission" do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    garden = garden_fixture()

    assert {:ok, operator} =
             Subscription.create_subscription(%{
               "garden_id" => garden.id,
               "name" => "tools",
               "seed_name" => "tools",
               "seed_type" => "package",
               "origin" => "declared"
             })

    assert operator.origin == "operator"

    config = %SowerClient.Orchestration.Subscription{
      name: "tools",
      seed_name: "tools",
      seed_type: "package",
      rules: [],
      policy: %{},
      origin: "operator"
    }

    assert {:error, :ownership_conflict} = Subscription.register_subscription(config, garden.id)
    assert {:ok, []} = Subscription.sync_subscriptions([], garden.id)
    assert Subscription.get_subscription_sid!(operator.sid).origin == "operator"
    assert [%{origin: "operator"}] = Subscription.managed_snapshot(garden)
  end

  test "declared provenance cannot be adopted by an operator create" do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    garden = garden_fixture()

    config = %SowerClient.Orchestration.Subscription{
      name: "shell",
      seed_name: "shell",
      seed_type: "devshell",
      rules: [],
      policy: %{},
      origin: "operator"
    }

    assert {:ok, declared} = Subscription.register_subscription(config, garden.id)
    assert declared.origin == "declared"

    assert {:error, :ownership_conflict} =
             Subscription.create_subscription(%{
               garden_id: garden.id,
               name: "shell",
               seed_name: "shell",
               seed_type: "devshell"
             })
  end
end
