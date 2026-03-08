defmodule SowerAgent.DeployerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  require Logger

  alias SowerAgent.Deployer
  alias SowerClient.Orchestration.Deployment
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

  describe "maybe_reboot/3" do
    test "skips reboot logic when deployment has no nixos seeds" do
      deployment = %Deployment{
        sid: "dep_non_nixos",
        seed_deployments: [seed_deploy("sub1", "service")]
      }

      assert Deployer.maybe_reboot(deployment, :success,
               reboot_reason_fun: fn _ ->
                 send(self(), :reboot_reason_called)
                 nil
               end,
               reboot_fun: fn _ ->
                 send(self(), :reboot_called)
                 {:ok, []}
               end,
               activation_enabled_fun: fn -> true end,
               report_seed_result_fun: fn _, _, _, _ -> :ok end
             ) == :ok

      refute_received :reboot_reason_called
      refute_received :reboot_called
    end

    test "evaluates reboot logic when deployment includes nixos seeds" do
      deployment = %Deployment{sid: "dep_nixos", seed_deployments: [seed_deploy("sub1", "nixos")]}

      assert Deployer.maybe_reboot(deployment, :success,
               reboot_reason_fun: fn _ ->
                 send(self(), :reboot_reason_called)
                 nil
               end,
               reboot_fun: fn _ -> flunk("reboot should not be requested") end,
               activation_enabled_fun: fn -> true end,
               report_seed_result_fun: fn _, _, _, _ -> :ok end
             ) == :ok

      assert_received :reboot_reason_called
    end

    test "requests reboot when nixos deployment requires it" do
      deployment = %Deployment{
        sid: "dep_reboot",
        seed_deployments: [seed_deploy("sub1", "nixos")]
      }

      assert Deployer.maybe_reboot(deployment, :success,
               reboot_reason_fun: fn _ -> "policy_always" end,
               reboot_fun: fn opts ->
                 send(self(), {:reboot_called, opts})
                 {:ok, ["ok"]}
               end,
               activation_enabled_fun: fn -> true end,
               report_seed_result_fun: fn _, _, _, _ -> :ok end
             ) == :ok

      assert_received {:reboot_called, [reason: "policy_always"]}
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

      read_link = fn
        "/nix/var/nix/profiles/system" -> {:ok, "/nix/store/sys-b"}
        "/run/current-system" -> {:ok, "/nix/store/sys-a"}
        "/run/booted-system" -> {:ok, "/nix/store/sys-a"}
      end

      assert Deployer.reboot_reason(seed_deployments, get_profile, read_link) == "boot_mode"
    end

    test "returns nil when boot profile already matches running and booted system" do
      seed_deployments = [seed_deploy("sub_boot")]

      get_profile = fn "sub_boot" ->
        %DeploymentProfile{activation_args: ["boot"], reboot_policy: "when-required"}
      end

      read_link = fn
        "/nix/var/nix/profiles/system" -> {:ok, "/nix/var/nix/profiles/system-123-link"}
        "/nix/var/nix/profiles/system-123-link" -> {:ok, "/nix/store/sys-a"}
        "/run/current-system" -> {:ok, "/nix/store/sys-a"}
        "/run/booted-system" -> {:ok, "/nix/store/sys-a"}
      end

      assert Deployer.reboot_reason(seed_deployments, get_profile, read_link) == nil
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

  describe "upgrade/2" do
    test "reports failure with fatal log line when activator is unavailable" do
      deployment = %Deployment{
        sid: "dep_1",
        seed_deployments: [seed_deploy_with_identity("seed_1")]
      }

      test_pid = self()

      logs =
        capture_log(fn ->
          assert [
                   {:ok, {:error, :activator_unavailable}}
                 ] =
                   Deployer.upgrade(deployment,
                     async_stream_fun: fn enumerable, func ->
                       Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
                     end,
                     realize_seed_fun: fn seed_deploy -> {:ok, seed_deploy} end,
                     get_deployment_profile_fun: fn _ -> %DeploymentProfile{} end,
                     activate_seed_fun: fn _seed, _profile -> {:error, :activator_unavailable} end,
                     report_seed_result_fun: fn _deployment, _seed, result, output_lines ->
                       send(test_pid, {:seed_result, result, output_lines})
                     end
                   )
        end)

      assert logs =~ "Missing activator during deployment activation"

      assert_received {:seed_result, :failure, lines}
      assert Enum.any?(lines, &(&1 =~ "FATAL: missing activator executable sower-activator"))
    end

    test "reports success for successful activation" do
      deployment = %Deployment{
        sid: "dep_2",
        seed_deployments: [seed_deploy_with_identity("seed_2")]
      }

      test_pid = self()

      capture_log(fn ->
        assert [
                 {:ok, {:ok, ["activation complete"]}}
               ] =
                 Deployer.upgrade(deployment,
                   async_stream_fun: fn enumerable, func ->
                     Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
                   end,
                   realize_seed_fun: fn seed_deploy -> {:ok, seed_deploy} end,
                   get_deployment_profile_fun: fn _ -> %DeploymentProfile{} end,
                   activate_seed_fun: fn _seed, _profile -> {:ok, ["activation complete"]} end,
                   report_seed_result_fun: fn _deployment, _seed, result, _output_lines ->
                     send(test_pid, {:seed_result, result})
                   end
                 )
      end)

      assert_received {:seed_result, :success}
    end

    test "reports failure with fatal log line when activator executable is missing" do
      deployment = %Deployment{
        sid: "dep_3",
        seed_deployments: [seed_deploy_with_identity("seed_3")]
      }

      test_pid = self()

      logs =
        capture_log(fn ->
          assert [
                   {:ok, {:error, :cmd_not_found}}
                 ] =
                   Deployer.upgrade(deployment,
                     async_stream_fun: fn enumerable, func ->
                       Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
                     end,
                     realize_seed_fun: fn seed_deploy -> {:ok, seed_deploy} end,
                     get_deployment_profile_fun: fn _ -> %DeploymentProfile{} end,
                     activate_seed_fun: fn _seed, _profile -> {:error, :cmd_not_found} end,
                     report_seed_result_fun: fn _deployment, _seed, result, output_lines ->
                       send(test_pid, {:seed_result, result, output_lines})
                     end
                   )
        end)

      assert logs =~ "Missing activator during deployment activation"
      assert logs =~ "cmd_not_found"

      assert_received {:seed_result, :failure, lines}
      assert Enum.any?(lines, &(&1 =~ "FATAL: missing activator executable sower-activator"))
    end
  end

  describe "decision_line/1" do
    test "formats message with [sower] prefix" do
      assert Deployer.decision_line("reboot triggered") == "[sower] reboot triggered"
    end
  end

  describe "deploy log decision lines" do
    test "includes realization success decision line in log output" do
      deployment = %Deployment{
        sid: "dep_real_ok",
        seed_deployments: [seed_deploy_with_identity("seed_r1")]
      }

      logged_lines = capture_seed_result_lines(deployment)

      assert Enum.any?(
               logged_lines,
               &(&1 =~ "[sower]" and &1 =~ "realized" and &1 =~ "seed-seed_r1")
             )
    end

    test "includes realization failure decision line in log output" do
      deployment = %Deployment{
        sid: "dep_real_fail",
        seed_deployments: [seed_deploy_with_identity("seed_rf1")]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          realize_seed_fun: fn seed_deploy -> {:error, :failed_to_realize, seed_deploy} end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[sower]" and &1 =~ "realization failed"))
    end

    test "includes activation mode decision line in log output" do
      deployment = %Deployment{
        sid: "dep_mode",
        seed_deployments: [seed_deploy_with_identity("seed_m1")]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          get_deployment_profile_fun: fn _ ->
            %DeploymentProfile{activation_args: ["boot"]}
          end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[sower]" and &1 =~ "boot" and &1 =~ "seed-seed_m1"))
    end

    test "includes reboot decision in last seed log" do
      deployment = %Deployment{
        sid: "dep_reboot_log",
        seed_deployments: [seed_deploy_with_identity("seed_rb1")]
      }

      test_pid = self()

      capture_log(fn ->
        Deployer.run_with_opts(deployment,
          upgrade_opts: [
            async_stream_fun: fn enumerable, func ->
              Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
            end,
            realize_seed_fun: fn sd -> {:ok, sd} end,
            get_deployment_profile_fun: fn _ ->
              %DeploymentProfile{reboot_policy: "always"}
            end,
            activate_seed_fun: fn _seed, _profile -> {:ok, ["ok"]} end,
            report_seed_result_fun: fn _deployment, _seed, result, output_lines ->
              send(test_pid, {:seed_result, result, output_lines})
            end
          ],
          reboot_opts: [
            reboot_reason_fun: fn _ -> "policy_always" end,
            reboot_fun: fn _opts -> {:ok, ["rebooting"]} end,
            activation_enabled_fun: fn -> true end
          ]
        )
      end)

      # First call: activation result
      assert_received {:seed_result, :success, _activation_lines}
      # Second call: reboot decision appended to last seed
      assert_received {:seed_result, nil, reboot_lines}

      assert Enum.any?(
               reboot_lines,
               &(&1 =~ "[sower]" and &1 =~ "reboot initiated: policy_always")
             )
    end

    test "includes reboot skipped in last seed log for failed deployment" do
      deployment = %Deployment{
        sid: "dep_reboot_skip",
        seed_deployments: [seed_deploy_with_identity("seed_rs1")]
      }

      test_pid = self()

      capture_log(fn ->
        Deployer.run_with_opts(deployment,
          upgrade_opts: [
            async_stream_fun: fn enumerable, func ->
              Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
            end,
            realize_seed_fun: fn sd -> {:ok, sd} end,
            get_deployment_profile_fun: fn _ -> %DeploymentProfile{} end,
            activate_seed_fun: fn _seed, _profile -> {:error, 1, ["failed"]} end,
            report_seed_result_fun: fn _deployment, _seed, result, output_lines ->
              send(test_pid, {:seed_result, result, output_lines})
            end
          ],
          reboot_opts: []
        )
      end)

      # First call: activation result
      assert_received {:seed_result, :failure, _activation_lines}
      # Second call: reboot decision
      assert_received {:seed_result, nil, reboot_lines}
      assert Enum.any?(reboot_lines, &(&1 =~ "[sower]" and &1 =~ "reboot skipped"))
    end

    test "includes default activation mode when none configured" do
      deployment = %Deployment{
        sid: "dep_mode_default",
        seed_deployments: [seed_deploy_with_identity("seed_md1")]
      }

      logged_lines = capture_seed_result_lines(deployment)

      assert Enum.any?(
               logged_lines,
               &(&1 =~ "[sower]" and &1 =~ "switch" and &1 =~ "seed-seed_md1")
             )
    end
  end

  defp capture_seed_result_lines(%Deployment{} = deployment, opts \\ []) do
    test_pid = self()

    capture_log(fn ->
      Deployer.upgrade(deployment,
        async_stream_fun: fn enumerable, func ->
          Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
        end,
        realize_seed_fun: Keyword.get(opts, :realize_seed_fun, fn sd -> {:ok, sd} end),
        get_deployment_profile_fun:
          Keyword.get(opts, :get_deployment_profile_fun, fn _ -> %DeploymentProfile{} end),
        activate_seed_fun:
          Keyword.get(opts, :activate_seed_fun, fn _seed, _profile ->
            {:ok, ["activation output"]}
          end),
        report_seed_result_fun: fn _deployment, _seed, _result, output_lines ->
          send(test_pid, {:seed_result_lines, output_lines})
        end
      )
    end)

    receive do
      {:seed_result_lines, lines} -> lines
    after
      1000 -> []
    end
  end

  defp seed_deploy(subscription_sid, seed_type \\ "nixos") do
    %SeedDeployment{
      subscription_sid: subscription_sid,
      seed: %Seed{seed_type: seed_type}
    }
  end

  defp seed_deploy_with_identity(seed_sid) do
    %SeedDeployment{
      subscription_sid: "sub_#{seed_sid}",
      seed: %Seed{
        sid: seed_sid,
        name: "seed-#{seed_sid}",
        seed_type: "nixos",
        artifact: "/nix/store/#{seed_sid}"
      }
    }
  end
end
