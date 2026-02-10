defmodule SowerAgent.DeployerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SowerAgent.Deployer
  alias SowerClient.Orchestration.DeploymentProfile
  alias SowerClient.Orchestration.Subscription

  describe "get_deploy_profile/3" do
    test "returns nil for nil subscription sid" do
      assert Deployer.get_deploy_profile(nil) == nil
    end

    test "returns defaults and logs warning when subscription is missing" do
      logs =
        capture_log(fn ->
          assert Deployer.get_deploy_profile("sub_missing", fn _sid -> nil end, fn _name ->
                   %{}
                 end) ==
                   %DeploymentProfile{}
        end)

      assert logs =~ "Subscription not found, using defaults"
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

      assert Deployer.get_deploy_profile(sid, find_sub, find_profile) == %DeploymentProfile{
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

      assert Deployer.get_deploy_profile(
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

      assert Deployer.get_deploy_profile(
               sid,
               fn _ -> sub end,
               fn _ -> nil end
             ) == %DeploymentProfile{}
    end
  end
end
