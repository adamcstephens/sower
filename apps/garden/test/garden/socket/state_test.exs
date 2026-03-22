defmodule Garden.Socket.StateTest do
  use ExUnit.Case, async: true

  alias Garden.Socket.State
  alias SowerClient.Orchestration.DeploymentRequest
  alias SowerClient.Orchestration.GardenSeedsReport

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
end
