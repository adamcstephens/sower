defmodule SowerAgent.DeployerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SowerAgent.Deployer
  alias SowerClient.Orchestration.SeedDeployment
  alias SowerClient.Orchestration.DeploymentProfile
  alias SowerClient.Orchestration.Subscription
  alias SowerClient.Seed

  describe "get_deployment_profile/3" do
    test "returns nil for nil subscription sid" do
      assert Deployer.get_deployment_profile(nil) == nil
    end

    test "returns defaults and logs when subscription is missing" do
      assert Deployer.get_deployment_profile("sub_missing", fn _sid -> nil end, fn _name ->
               %{}
             end) ==
               %DeploymentProfile{}
    end

    test "uses the default profile name when subscription deployment profile is not set" do
      sid = "sub_default"

      sub = %Subscription{
        sid: sid,
        seed_name: "kale",
        seed_type: "nixos"
      }

      assert Deployer.get_deployment_profile(
               sid,
               fn _ -> sub end,
               fn
                 "default" -> %{activation_args: ["boot"], reboot_policy: "always"}
                 other -> flunk("expected \"default\" profile lookup, got: #{inspect(other)}")
               end
             ) == %DeploymentProfile{
               activation_args: ["boot"],
               reboot_policy: "always"
             }
    end

    test "uses subscription deployment_profile string to resolve named profile overrides" do
      sid = "sub_boot"
      profile_name = "boot_profile"

      sub = %Subscription{
        sid: sid,
        deployment_profile: profile_name
      }

      find_sub = fn
        ^sid -> sub
        _ -> nil
      end

      find_profile = fn
        ^profile_name -> %{activation_args: ["boot"], reboot_policy: "always"}
        _ -> %{}
      end

      assert Deployer.get_deployment_profile(sid, find_sub, find_profile) == %DeploymentProfile{
               activation_args: ["boot"],
               reboot_policy: "always"
             }
    end

    test "keeps defaults for fields not present in resolved profile overrides" do
      sid = "sub_partial"

      sub = %Subscription{
        sid: sid,
        deployment_profile: "partial_profile"
      }

      assert Deployer.get_deployment_profile(
               sid,
               fn _ -> sub end,
               fn _ -> %{activation_args: ["boot"]} end
             ) == %DeploymentProfile{
               activation_args: ["boot"],
               reboot_policy: "never"
             }
    end

    test "falls back to defaults when named profile is not found" do
      sid = "sub_unknown_profile"

      sub = %Subscription{
        sid: sid,
        deployment_profile: "missing_profile"
      }

      assert Deployer.get_deployment_profile(
               sid,
               fn _ -> sub end,
               fn _ -> nil end
             ) == %DeploymentProfile{}
    end
  end

  describe "deployment_result/1" do
    test "returns :success when all seed activations succeed" do
      result = [{:ok, {:ok, ["ok"]}}, {:ok, {:ok, ["ok"]}}]
      assert Deployer.deployment_result(result) == :success
    end

    test "returns :partial when some seed activations fail" do
      result = [{:ok, {:ok, ["ok"]}}, {:ok, {:error, 1, ["failed"]}}]
      assert Deployer.deployment_result(result) == :partial
    end

    test "returns :failure when all seed activations fail" do
      result = [{:ok, {:error, 1, ["failed"]}}, {:error, :failed_to_realize, %{}}]
      assert Deployer.deployment_result(result) == :failure
    end
  end

  describe "reboot_reason/3" do
    test "returns nil when there are no nixos seed deployments" do
      seed_deployments = [seed_deploy("sub1", "home-manager")]

      assert Deployer.reboot_reason(seed_deployments, fn _ -> %DeploymentProfile{} end) == nil
    end

    test "returns policy_always when profile reboot policy is always" do
      seed_deployments = [seed_deploy("sub_always")]

      get_profile = fn "sub_always" ->
        %DeploymentProfile{activation_args: ["switch"], reboot_policy: "always"}
      end

      assert Deployer.reboot_reason(seed_deployments, get_profile) == "policy_always"
    end

    test "returns boot_mode when profile is when-required and activation mode is boot" do
      seed_deployments = [seed_deploy("sub_boot")]

      get_profile = fn "sub_boot" ->
        %DeploymentProfile{activation_args: ["boot"], reboot_policy: "when-required"}
      end

      assert Deployer.reboot_reason(seed_deployments, get_profile) == "boot_mode"
    end

    test "returns initrd_changed when when-required switch profile has boot-critical changes" do
      seed_deployments = [seed_deploy("sub_switch")]

      get_profile = fn "sub_switch" ->
        %DeploymentProfile{activation_args: ["switch"], reboot_policy: "when-required"}
      end

      read_link = fn
        "/nix/var/nix/profiles/system" -> {:ok, "/nix/store/sys-a"}
        "/run/current-system" -> {:ok, "/nix/store/sys-a"}
        "/run/booted-system" -> {:ok, "/nix/store/sys-b"}
      end

      assert Deployer.reboot_reason(seed_deployments, get_profile, read_link) == "initrd_changed"
    end

    test "returns nil and logs warning when boot-critical detection cannot read links" do
      seed_deployments = [seed_deploy("sub_switch")]

      get_profile = fn "sub_switch" ->
        %DeploymentProfile{activation_args: ["switch"], reboot_policy: "when-required"}
      end

      logs =
        capture_log(fn ->
          assert Deployer.reboot_reason(seed_deployments, get_profile, fn _ ->
                   {:error, :enoent}
                 end) ==
                   nil
        end)

      assert logs =~ "Could not evaluate reboot requirement from system profile links"
    end
  end

  defp seed_deploy(subscription_sid, seed_type \\ "nixos") do
    %SeedDeployment{
      subscription_sid: subscription_sid,
      seed: %Seed{seed_type: seed_type}
    }
  end
end
