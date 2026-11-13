defmodule Garden.Socket.LifecycleTest do
  use ExUnit.Case, async: true

  alias Garden.Socket.Lifecycle

  alias SowerClient.Orchestration.DeploymentRequest
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.GardenSeedsReport
  alias SowerClient.Orchestration.Subscription

  test "old-peer log payload omits destination keys entirely while capable peers retain them" do
    log = %SowerClient.Orchestration.SeedDeploymentLog{
      deployment_sid: "deployment",
      seed_sid: "seed",
      subscription_sid: "subscription",
      sequence: 1,
      output: "realizing"
    }

    legacy = log |> Lifecycle.payload_for_peer(false) |> Jason.encode!() |> Jason.decode!()
    refute Map.has_key?(legacy, "subscription_sid")
    assert legacy["output"] == "realizing"
    assert Lifecycle.payload_for_peer(log, true).subscription_sid == "subscription"
  end

  describe "refresh_managed_subscriptions/2" do
    test "merges only retention into exact local destinations without removing missing entries" do
      legacy = Subscription.cast!(%{name: "host", seed_name: "host", seed_type: "nixos"})

      frontend =
        Subscription.cast!(%{
          name: "frontend",
          sid: "sub_frontend",
          seed_name: "application",
          seed_type: "package",
          schedule: "0 * * * *"
        })

      missing =
        Subscription.cast!(%{
          name: "missing",
          sid: "sub_missing",
          seed_name: "application",
          seed_type: "package",
          retention: %{keep_days: 30}
        })

      snapshot = [
        %{
          name: "frontend",
          sid: "sub_frontend",
          seed_name: "application",
          seed_type: "package",
          retention: %{keep_generations: 3}
        },
        %{name: "worker", sid: "sub_worker", seed_name: "application", seed_type: "package"}
      ]

      assert {:ok, [^legacy, refreshed, ^missing]} =
               Lifecycle.refresh_managed_subscriptions([legacy, frontend, missing], snapshot)

      assert refreshed == %{frontend | retention: refreshed.retention}
      assert refreshed.retention.keep_generations == 3
    end

    test "materializes operator bindings, updates their fields, and preserves omitted bindings" do
      incoming = %{
        name: "operator-app",
        sid: "operator-sub",
        seed_name: "application",
        seed_type: "package",
        origin: "operator"
      }

      assert {:ok, [created]} = Lifecycle.refresh_managed_subscriptions([], [incoming])
      assert created.origin == "operator"

      changed = Map.put(incoming, :seed_name, "new-application")
      assert {:ok, [updated]} = Lifecycle.refresh_managed_subscriptions([created], [changed])
      assert updated.seed_name == "new-application"
      assert {:ok, [^updated]} = Lifecycle.refresh_managed_subscriptions([updated], [])
    end

    test "operator bindings cannot take over declared destinations" do
      declared =
        Subscription.cast!(%{
          name: "application",
          sid: "declared-sub",
          seed_name: "application",
          seed_type: "package"
        })

      incoming = %{
        name: "application",
        sid: "operator-sub",
        seed_name: "application",
        seed_type: "package",
        origin: "operator"
      }

      assert {:error, {:ownership_conflict, "application"}} =
               Lifecycle.refresh_managed_subscriptions([declared], [incoming])
    end

    test "an invalid snapshot is rejected rather than partially applied" do
      assert {:error, :not_managed_subscription} =
               Lifecycle.refresh_managed_subscriptions([], [
                 %{name: "host", seed_name: "host", seed_type: "nixos"}
               ])
    end
  end

  describe "profile operation outcomes" do
    test "uninstall preview never acknowledges completed removal" do
      operation =
        SowerClient.Orchestration.ProfileOperation.cast!(%{
          request_id: "preview",
          profile_name: "application",
          action: "uninstall",
          preview: true
        })

      profile =
        SowerClient.Orchestration.GardenSeedProfile.cast!(%{
          name: "application",
          profile_path: "/var/lib/sower-profiles/application/profile",
          generations: []
        })

      result = Lifecycle.profile_operation_result(operation, {:ok, profile})

      assert result.status == "preview"
      assert result.request_id == "preview"
      assert result.warning =~ "External services are not stopped"
    end

    test "pinned generations block removal rather than acknowledging success" do
      operation =
        SowerClient.Orchestration.ProfileOperation.cast!(%{
          request_id: "uninstall",
          profile_name: "application",
          action: "uninstall",
          preview: false
        })

      result = Lifecycle.profile_operation_result(operation, {:error, :pinned_generations})

      assert result.status == "blocked"
      assert result.error == "pinned_generations"

      completed = Lifecycle.profile_operation_result(operation, {:ok, :uninstalled})
      assert completed.status == "completed"
    end
  end

  describe "build_deployment_request/2" do
    test "builds request with subscription sid" do
      {:ok, %DeploymentRequest{} = request} = Lifecycle.build_deployment_request("sub_123", false)

      assert request.subscription_sids == ["sub_123"]
      assert request.request_id != nil
    end

    test "sets force flag when true" do
      {:ok, %DeploymentRequest{} = request} = Lifecycle.build_deployment_request("sub_123", true)

      assert request.force == true
    end

    test "omits force flag when false" do
      {:ok, %DeploymentRequest{} = request} = Lifecycle.build_deployment_request("sub_123", false)

      assert request.force == false
    end
  end

  describe "build_seed_report/1" do
    test "returns report when profiles are found" do
      subscriptions = [%{seed_type: "nixos", seed_name: "host", rules: []}]

      report =
        GardenSeedsReport.cast!(%{
          profiles: [%{profile_path: "/nix/var/nix/profiles/system", tags: %{}, generations: []}]
        })

      assert {:report, ^report} =
               Lifecycle.build_seed_report(subscriptions, fn _subs -> report end)
    end

    test "returns no_profiles when subscriptions exist but no profiles found" do
      subscriptions = [%{seed_type: "nixos", seed_name: "host", rules: []}]
      report = GardenSeedsReport.cast!(%{profiles: []})

      assert :no_profiles = Lifecycle.build_seed_report(subscriptions, fn _subs -> report end)
    end

    test "returns report when subscriptions are empty" do
      report = GardenSeedsReport.cast!(%{profiles: []})

      assert {:report, ^report} = Lifecycle.build_seed_report([], fn _subs -> report end)
    end

    test "reports an inventory failure even when no profiles were observed" do
      report =
        GardenSeedsReport.cast!(%{
          profiles: [],
          complete: false,
          failed_profile_paths: ["/var/lib/sower-profiles"]
        })

      subscriptions = [%{name: "application", seed_type: "package", seed_name: "application"}]

      assert {:report, ^report} =
               Lifecycle.build_seed_report(subscriptions, fn _subscriptions -> report end)
    end
  end

  describe "merge_subscriptions/2" do
    test "merges server-assigned sids into config subscriptions" do
      config_subs = [
        Subscription.cast!(%{
          name: "host",
          seed_name: "host",
          seed_type: "nixos",
          policy: %{"default" => %{actions: ["activate"], triggers: ["poll_on_connect"]}}
        }),
        Subscription.cast!(%{name: "user", seed_name: "user", seed_type: "home-manager"})
      ]

      registered = [
        %{"name" => "host", "seed_name" => "host", "seed_type" => "nixos", "sid" => "sub_abc"},
        %{
          "name" => "user",
          "seed_name" => "user",
          "seed_type" => "home-manager",
          "sid" => "sub_def"
        }
      ]

      result = Lifecycle.merge_subscriptions(config_subs, registered)

      assert length(result) == 2
      assert Enum.find(result, &(&1.seed_name == "host")).sid == "sub_abc"
      assert Enum.find(result, &(&1.seed_name == "user")).sid == "sub_def"
    end

    test "uses effective retention only with a capable peer without changing declared config" do
      configured =
        Subscription.cast!(%{
          name: "application",
          seed_name: "application",
          seed_type: "package",
          retention: %{keep_generations: 3}
        })

      registered = [
        %{
          name: "application",
          seed_name: "application",
          seed_type: "package",
          sid: "subscription",
          retention: nil
        }
      ]

      assert [effective] = Lifecycle.merge_subscriptions([configured], registered, true)
      assert effective.retention == nil
      assert configured.retention.keep_generations == 3
      assert [legacy] = Lifecycle.merge_subscriptions([configured], registered, false)
      assert legacy.retention == configured.retention
    end

    test "drops config subscriptions not registered on server" do
      config_subs = [
        Subscription.cast!(%{name: "host", seed_name: "host", seed_type: "nixos"}),
        Subscription.cast!(%{name: "orphan", seed_name: "orphan", seed_type: "nixos"})
      ]

      registered = [
        %{"name" => "host", "seed_name" => "host", "seed_type" => "nixos", "sid" => "sub_abc"}
      ]

      result = Lifecycle.merge_subscriptions(config_subs, registered)

      assert length(result) == 1
      assert hd(result).seed_name == "host"
    end

    test "keeps distinct destinations for subscriptions sharing a seed" do
      config_subs =
        Enum.map(["frontend", "worker"], fn name ->
          Subscription.cast!(%{name: name, seed_name: "application", seed_type: "package"})
        end)

      registered = [
        %{
          "name" => "worker",
          "seed_name" => "application",
          "seed_type" => "package",
          "sid" => "sub_worker"
        },
        %{
          "name" => "frontend",
          "seed_name" => "application",
          "seed_type" => "package",
          "sid" => "sub_frontend"
        }
      ]

      assert Enum.map(Lifecycle.merge_subscriptions(config_subs, registered), &{&1.name, &1.sid}) ==
               [{"frontend", "sub_frontend"}, {"worker", "sub_worker"}]
    end

    test "returns empty list for empty registered" do
      config_subs = [
        Subscription.cast!(%{name: "host", seed_name: "host", seed_type: "nixos"})
      ]

      assert Lifecycle.merge_subscriptions(config_subs, []) == []
    end
  end

  describe "poll_on_connect_subscriptions/1" do
    test "includes subscriptions with poll_on_connect in policy" do
      subs = [
        Subscription.cast!(%{
          name: "host",
          seed_name: "host",
          seed_type: "nixos",
          sid: "sub_1",
          policy: %{
            "default" => %{actions: ["activate"], triggers: ["poll_on_connect"]}
          }
        }),
        Subscription.cast!(%{
          name: "user",
          seed_name: "user",
          seed_type: "home-manager",
          sid: "sub_2",
          policy: %{
            "default" => %{actions: ["activate"], triggers: ["manual"]}
          }
        })
      ]

      result = Lifecycle.poll_on_connect_subscriptions(subs)

      assert length(result) == 1
      assert hd(result).seed_name == "host"
    end

    test "returns empty list when no policy permits poll_on_connect" do
      subs = [
        Subscription.cast!(%{
          name: "host",
          seed_name: "host",
          seed_type: "nixos",
          sid: "sub_1",
          policy: %{
            "default" => %{actions: ["activate"], triggers: ["manual", "scheduled"]}
          }
        })
      ]

      assert Lifecycle.poll_on_connect_subscriptions(subs) == []
    end

    test "default policy includes poll_on_connect" do
      subs = [
        Subscription.cast!(%{name: "host", seed_name: "host", seed_type: "nixos", sid: "sub_1"})
      ]

      assert length(Lifecycle.poll_on_connect_subscriptions(subs)) == 1
    end
  end

  describe "receive_deployment/2" do
    test "enqueues new deployment" do
      deployment = %Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      assert {:enqueue, active} = Lifecycle.receive_deployment(deployment, %{})
      assert Map.has_key?(active, "deploy_123")
      assert active["deploy_123"].sid == "deploy_123"
    end

    test "returns duplicate for already active deployment" do
      deployment = %Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      active = %{"deploy_123" => deployment}

      assert :duplicate = Lifecycle.receive_deployment(deployment, active)
    end

    test "returns skipped for skipped deployment" do
      deployment = %Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: true
      }

      assert :skipped = Lifecycle.receive_deployment(deployment, %{})
    end

    test "allows simultaneous deployments for different sids" do
      d1 = %Deployment{sid: "deploy_1", request_id: "dr_1", seed_deployments: [], skipped: false}
      d2 = %Deployment{sid: "deploy_2", request_id: "dr_2", seed_deployments: [], skipped: false}

      {:enqueue, active} = Lifecycle.receive_deployment(d1, %{})
      {:enqueue, active} = Lifecycle.receive_deployment(d2, active)

      assert map_size(active) == 2
    end
  end

  describe "lookup_deployment/2" do
    test "returns deployment when found" do
      deployment = %Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      active = %{"deploy_123" => deployment}

      assert {:ok, ^deployment} = Lifecycle.lookup_deployment("deploy_123", active)
    end

    test "returns not_found when missing" do
      assert :not_found = Lifecycle.lookup_deployment("deploy_123", %{})
    end
  end

  describe "complete_deployment/3" do
    test "returns result and removes deployment from active map" do
      deployment = %Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: false
      }

      active = %{"deploy_123" => deployment}

      assert {:ok, result, updated_active} =
               Lifecycle.complete_deployment("deploy_123", :success, active)

      assert result.request_id == "dr_456"
      assert result.deployment_sid == "deploy_123"
      assert result.result == :success
      assert result.deployed_at != nil
      assert updated_active == %{}
    end

    test "returns not_found when deployment missing" do
      assert :not_found = Lifecycle.complete_deployment("deploy_123", :success, %{})
    end

    test "preserves other deployments in map" do
      d1 = %Deployment{sid: "deploy_1", request_id: "dr_1", seed_deployments: [], skipped: false}
      d2 = %Deployment{sid: "deploy_2", request_id: "dr_2", seed_deployments: [], skipped: false}

      active = %{"deploy_1" => d1, "deploy_2" => d2}

      {:ok, _result, updated_active} = Lifecycle.complete_deployment("deploy_1", :success, active)

      assert map_size(updated_active) == 1
      assert Map.has_key?(updated_active, "deploy_2")
    end
  end

  describe "should_reload?/2" do
    test "takes a pending reload when no deployments are active" do
      take_pending_reload = fn ->
        send(self(), :reload_taken)
        true
      end

      assert Lifecycle.should_reload?(%{}, take_pending_reload)
      assert_received :reload_taken
    end

    test "does not consume a pending reload while a deployment is active" do
      active = %{
        "deploy_1" => %Deployment{
          sid: "deploy_1",
          request_id: "dr_1",
          seed_deployments: [],
          skipped: false
        }
      }

      take_pending_reload = fn ->
        send(self(), :reload_taken)
        true
      end

      refute Lifecycle.should_reload?(active, take_pending_reload)
      refute_received :reload_taken
    end

    test "returns false when no reload is pending" do
      refute Lifecycle.should_reload?(%{}, fn -> false end)
    end
  end
end

defmodule Garden.Socket.Lifecycle.CredentialRejectionTest do
  use ExUnit.Case, async: true

  alias Garden.Socket.Lifecycle

  describe "rejection_action/1" do
    test "awaits the operator on an unknown client" do
      assert :await_operator =
               Lifecycle.rejection_action({:server_rejected, 400, :unknown_client})
    end

    test "retries the existing registration on a bare 400" do
      assert :retry = Lifecycle.rejection_action({:server_rejected, 400, :unclassified})
    end

    test "retries the existing registration on an expired assertion" do
      assert :retry = Lifecycle.rejection_action({:server_rejected, 400, :assertion_expired})
    end

    test "retries the existing registration on a signature mismatch" do
      assert :retry = Lifecycle.rejection_action({:server_rejected, 401, :invalid_signature})
    end

    test "retries on server errors and transport failures" do
      assert :retry = Lifecycle.rejection_action({:server_error, 503})
      assert :retry = Lifecycle.rejection_action({:transport_error, :closed})
    end
  end

  describe "reconnect_delay/2" do
    test "walks the backoff curve and holds at the ceiling" do
      backoff = [200, 1_000, 5_000]

      assert 200 = Lifecycle.reconnect_delay(0, backoff)
      assert 1_000 = Lifecycle.reconnect_delay(1, backoff)
      assert 5_000 = Lifecycle.reconnect_delay(2, backoff)
      assert 5_000 = Lifecycle.reconnect_delay(99, backoff)
    end

    test "the default curve climbs into the minutes" do
      backoff = Lifecycle.default_backoff()

      assert Enum.sort(backoff) == backoff
      assert List.last(backoff) >= 300_000
    end
  end
end
