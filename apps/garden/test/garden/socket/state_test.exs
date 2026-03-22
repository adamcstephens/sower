defmodule Garden.Socket.StateTest do
  use ExUnit.Case, async: true

  alias Garden.Socket.State
  alias SowerClient.Orchestration.DeploymentRequest
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.GardenSeedsReport
  alias SowerClient.Orchestration.Subscription

  describe "build_deployment_request/2" do
    test "builds request with subscription sid" do
      {:ok, %DeploymentRequest{} = request} = State.build_deployment_request("sub_123", false)

      assert request.subscription_sids == ["sub_123"]
      assert request.request_id != nil
    end

    test "sets force flag when true" do
      {:ok, %DeploymentRequest{} = request} = State.build_deployment_request("sub_123", true)

      assert request.force == true
    end

    test "omits force flag when false" do
      {:ok, %DeploymentRequest{} = request} = State.build_deployment_request("sub_123", false)

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
               State.build_seed_report(subscriptions, fn _subs -> report end)
    end

    test "returns no_profiles when subscriptions exist but no profiles found" do
      subscriptions = [%{seed_type: "nixos", seed_name: "host", rules: []}]
      report = GardenSeedsReport.cast!(%{profiles: []})

      assert :no_profiles = State.build_seed_report(subscriptions, fn _subs -> report end)
    end

    test "returns report when subscriptions are empty" do
      report = GardenSeedsReport.cast!(%{profiles: []})

      assert {:report, ^report} = State.build_seed_report([], fn _subs -> report end)
    end
  end

  describe "merge_subscriptions/2" do
    test "merges server-assigned sids into config subscriptions" do
      config_subs = [
        Subscription.cast!(%{seed_name: "host", seed_type: "nixos", poll_on_connect: true}),
        Subscription.cast!(%{seed_name: "user", seed_type: "home-manager"})
      ]

      registered = [
        %{"seed_name" => "host", "seed_type" => "nixos", "sid" => "sub_abc"},
        %{"seed_name" => "user", "seed_type" => "home-manager", "sid" => "sub_def"}
      ]

      result = State.merge_subscriptions(config_subs, registered)

      assert length(result) == 2
      assert Enum.find(result, &(&1.seed_name == "host")).sid == "sub_abc"
      assert Enum.find(result, &(&1.seed_name == "host")).poll_on_connect == true
      assert Enum.find(result, &(&1.seed_name == "user")).sid == "sub_def"
    end

    test "drops config subscriptions not registered on server" do
      config_subs = [
        Subscription.cast!(%{seed_name: "host", seed_type: "nixos"}),
        Subscription.cast!(%{seed_name: "orphan", seed_type: "nixos"})
      ]

      registered = [
        %{"seed_name" => "host", "seed_type" => "nixos", "sid" => "sub_abc"}
      ]

      result = State.merge_subscriptions(config_subs, registered)

      assert length(result) == 1
      assert hd(result).seed_name == "host"
    end

    test "returns empty list for empty registered" do
      config_subs = [
        Subscription.cast!(%{seed_name: "host", seed_type: "nixos"})
      ]

      assert State.merge_subscriptions(config_subs, []) == []
    end
  end

  describe "poll_on_connect_subscriptions/1" do
    test "filters to subscriptions with poll_on_connect true" do
      subs = [
        Subscription.cast!(%{
          seed_name: "host",
          seed_type: "nixos",
          poll_on_connect: true,
          sid: "sub_1"
        }),
        Subscription.cast!(%{seed_name: "user", seed_type: "home-manager", sid: "sub_2"})
      ]

      result = State.poll_on_connect_subscriptions(subs)

      assert length(result) == 1
      assert hd(result).seed_name == "host"
    end

    test "returns empty list when none have poll_on_connect" do
      subs = [
        Subscription.cast!(%{seed_name: "host", seed_type: "nixos", sid: "sub_1"})
      ]

      assert State.poll_on_connect_subscriptions(subs) == []
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

      assert {:enqueue, active} = State.receive_deployment(deployment, %{})
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

      assert :duplicate = State.receive_deployment(deployment, active)
    end

    test "returns skipped for skipped deployment" do
      deployment = %Deployment{
        sid: "deploy_123",
        request_id: "dr_456",
        seed_deployments: [],
        skipped: true
      }

      assert :skipped = State.receive_deployment(deployment, %{})
    end

    test "allows simultaneous deployments for different sids" do
      d1 = %Deployment{sid: "deploy_1", request_id: "dr_1", seed_deployments: [], skipped: false}
      d2 = %Deployment{sid: "deploy_2", request_id: "dr_2", seed_deployments: [], skipped: false}

      {:enqueue, active} = State.receive_deployment(d1, %{})
      {:enqueue, active} = State.receive_deployment(d2, active)

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

      assert {:ok, ^deployment} = State.lookup_deployment("deploy_123", active)
    end

    test "returns not_found when missing" do
      assert :not_found = State.lookup_deployment("deploy_123", %{})
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
               State.complete_deployment("deploy_123", :success, active)

      assert result.request_id == "dr_456"
      assert result.deployment_sid == "deploy_123"
      assert result.result == :success
      assert result.deployed_at != nil
      assert updated_active == %{}
    end

    test "returns not_found when deployment missing" do
      assert :not_found = State.complete_deployment("deploy_123", :success, %{})
    end

    test "preserves other deployments in map" do
      d1 = %Deployment{sid: "deploy_1", request_id: "dr_1", seed_deployments: [], skipped: false}
      d2 = %Deployment{sid: "deploy_2", request_id: "dr_2", seed_deployments: [], skipped: false}

      active = %{"deploy_1" => d1, "deploy_2" => d2}

      {:ok, _result, updated_active} = State.complete_deployment("deploy_1", :success, active)

      assert map_size(updated_active) == 1
      assert Map.has_key?(updated_active, "deploy_2")
    end
  end

  describe "should_reload?/2" do
    test "returns true when no active deployments and pending reload" do
      assert State.should_reload?(%{}, true)
    end

    test "returns false when active deployments exist" do
      active = %{
        "deploy_1" => %Deployment{
          sid: "deploy_1",
          request_id: "dr_1",
          seed_deployments: [],
          skipped: false
        }
      }

      refute State.should_reload?(active, true)
    end

    test "returns false when no pending reload" do
      refute State.should_reload?(%{}, false)
    end
  end
end
