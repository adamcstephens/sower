defmodule Garden.DeployerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Garden.Deployer
  alias SowerClient.Orchestration.Deployment
  alias SowerClient.Orchestration.SeedDeployment
  alias SowerClient.Orchestration.Subscription
  alias SowerClient.Seed

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
               reboot_fun: fn _ ->
                 send(self(), :reboot_called)
                 {:ok, []}
               end,
               activation_enabled_fun: fn -> true end,
               report_seed_status_fun: fn _, _, _ -> :ok end,
               report_seed_result_fun: fn _, _, _, _ -> :ok end
             ) == :ok

      refute_received :reboot_called
    end

    test "skips reboot when reboot_reason returns nil" do
      deployment = %Deployment{sid: "dep_nixos", seed_deployments: [seed_deploy("sub1", "nixos")]}

      assert Deployer.maybe_reboot(deployment, :success,
               reboot_reason_fun: fn _ -> nil end,
               reboot_fun: fn _ -> flunk("reboot should not be requested") end,
               activation_enabled_fun: fn -> true end,
               report_seed_status_fun: fn _, _, _ -> :ok end,
               report_seed_result_fun: fn _, _, _, _ -> :ok end
             ) == :ok
    end

    test "requests reboot when nixos deployment requires it" do
      deployment = %Deployment{
        sid: "dep_reboot",
        seed_deployments: [seed_deploy("sub1", "nixos")]
      }

      assert Deployer.maybe_reboot(deployment, :success,
               reboot_reason_fun: fn _ -> "system_changed" end,
               reboot_fun: fn opts ->
                 send(self(), {:reboot_called, opts})
                 {:ok, ["ok"]}
               end,
               activation_enabled_fun: fn -> true end,
               report_seed_status_fun: fn _, _, _ -> :ok end,
               report_seed_result_fun: fn _, _, _, _ -> :ok end
             ) == :ok

      assert_received {:reboot_called, [reason: "system_changed"]}
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
                     realize_seed_fun: fn seed_deploy -> {:ok, seed_deploy, []} end,
                     find_subscription_fun: fn _ -> %Subscription{} end,
                     activate_seed_fun: fn _seed, _profile -> {:error, :activator_unavailable} end,
                     report_seed_status_fun: fn _, _, _ -> :ok end,
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
                   realize_seed_fun: fn seed_deploy -> {:ok, seed_deploy, []} end,
                   find_subscription_fun: fn _ -> %Subscription{} end,
                   activate_seed_fun: fn _seed, _profile -> {:ok, ["activation complete"]} end,
                   report_seed_status_fun: fn _, _, _ -> :ok end,
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
                     realize_seed_fun: fn seed_deploy -> {:ok, seed_deploy, []} end,
                     find_subscription_fun: fn _ -> %Subscription{} end,
                     activate_seed_fun: fn _seed, _profile -> {:error, :cmd_not_found} end,
                     report_seed_status_fun: fn _, _, _ -> :ok end,
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
    test "formats message with ISO 8601 timestamp and [garden] prefix" do
      line = Deployer.decision_line("reboot triggered")

      assert line =~
               ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z \[garden\] reboot triggered$/
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
               &(&1 =~ "[garden]" and &1 =~ "realized" and &1 =~ "seed-seed_r1")
             )
    end

    test "includes realization failure decision line in log output" do
      deployment = %Deployment{
        sid: "dep_real_fail",
        seed_deployments: [seed_deploy_with_identity("seed_rf1")]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          realize_seed_fun: fn seed_deploy -> {:error, :failed_to_realize, seed_deploy, []} end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "realization failed"))
    end

    test "includes activation mode decision line in log output" do
      deployment = %Deployment{
        sid: "dep_mode",
        seed_deployments: [seed_deploy_with_identity("seed_m1")]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          find_subscription_fun: fn _ ->
            %Subscription{
              seed_type: "nixos",
              policy: [%{actions: ["restart"]}]
            }
          end
        )

      assert Enum.any?(
               logged_lines,
               &(&1 =~ "[garden]" and &1 =~ "boot" and &1 =~ "seed-seed_m1")
             )
    end

    test "uses restart mode for service seed type with activate action" do
      deployment = %Deployment{
        sid: "dep_svc",
        seed_deployments: [seed_deploy_with_identity("seed_svc1", "service")]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          find_subscription_fun: fn _ ->
            %Subscription{
              seed_type: "service",
              policy: [%{actions: ["activate"]}]
            }
          end
        )

      assert Enum.any?(
               logged_lines,
               &(&1 =~ "[garden]" and &1 =~ "restart" and &1 =~ "seed-seed_svc1")
             )
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
            realize_seed_fun: fn sd -> {:ok, sd, []} end,
            find_subscription_fun: fn _ ->
              %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}
            end,
            activate_seed_fun: fn _seed, _mode -> {:ok, ["ok"]} end,
            report_seed_result_fun: fn _deployment, _seed, result, output_lines ->
              send(test_pid, {:seed_result, result, output_lines})
            end
          ],
          reboot_opts: [
            reboot_reason_fun: fn _ -> "system_changed" end,
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
               &(&1 =~ "[garden]" and &1 =~ "reboot initiated: system_changed")
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
            realize_seed_fun: fn sd -> {:ok, sd, []} end,
            find_subscription_fun: fn _ -> %Subscription{} end,
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
      assert Enum.any?(reboot_lines, &(&1 =~ "[garden]" and &1 =~ "reboot skipped"))
    end

    test "includes downloading decision line before download output" do
      deployment = %Deployment{
        sid: "dep_dl_start",
        seed_deployments: [seed_deploy_with_identity("seed_ds1")]
      }

      download_lines = ["copying path '/nix/store/abc123'"]

      logged_lines =
        capture_seed_result_lines(deployment,
          realize_seed_fun: fn sd -> {:ok, sd, download_lines} end
        )

      assert Enum.at(logged_lines, 0) =~ "[garden]"
      assert Enum.at(logged_lines, 0) =~ "downloading seed-seed_ds1 (nixos)"
      assert Enum.at(logged_lines, 1) == "copying path '/nix/store/abc123'"
    end

    test "includes downloading decision line in failure log" do
      deployment = %Deployment{
        sid: "dep_dl_start_fail",
        seed_deployments: [seed_deploy_with_identity("seed_dsf1")]
      }

      download_lines = ["error: path '/nix/store/missing' is not valid"]

      logged_lines =
        capture_seed_result_lines(deployment,
          realize_seed_fun: fn sd -> {:error, :failed_to_realize, sd, download_lines} end
        )

      assert Enum.at(logged_lines, 0) =~ "[garden]"
      assert Enum.at(logged_lines, 0) =~ "downloading seed-seed_dsf1 (nixos)"
      assert Enum.at(logged_lines, 1) == "error: path '/nix/store/missing' is not valid"
    end

    test "includes download output in log before decision lines" do
      deployment = %Deployment{
        sid: "dep_dl_log",
        seed_deployments: [seed_deploy_with_identity("seed_dl1")]
      }

      download_lines = ["copying path '/nix/store/abc123'", "copying path '/nix/store/def456'"]

      logged_lines =
        capture_seed_result_lines(deployment,
          realize_seed_fun: fn sd -> {:ok, sd, download_lines} end
        )

      assert Enum.at(logged_lines, 1) == "copying path '/nix/store/abc123'"
      assert Enum.at(logged_lines, 2) == "copying path '/nix/store/def456'"
      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "realized"))
    end

    test "includes download output in failure log" do
      deployment = %Deployment{
        sid: "dep_dl_fail",
        seed_deployments: [seed_deploy_with_identity("seed_dlf1")]
      }

      download_lines = ["error: path '/nix/store/missing' is not valid"]

      logged_lines =
        capture_seed_result_lines(deployment,
          realize_seed_fun: fn sd -> {:error, :failed_to_realize, sd, download_lines} end
        )

      assert Enum.at(logged_lines, 1) == "error: path '/nix/store/missing' is not valid"
      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "realization failed"))
    end

    test "includes default activation mode when none configured" do
      deployment = %Deployment{
        sid: "dep_mode_default",
        seed_deployments: [seed_deploy_with_identity("seed_md1")]
      }

      logged_lines = capture_seed_result_lines(deployment)

      assert Enum.any?(
               logged_lines,
               &(&1 =~ "[garden]" and &1 =~ "switch" and &1 =~ "seed-seed_md1")
             )
    end
  end

  describe "server-proposed action" do
    test "honours a wire action the local garden policy permits" do
      deployment = %Deployment{
        sid: "dep_wire_restart",
        seed_deployments: [%{seed_deploy_with_identity("seed_w1") | action: "restart"}]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          garden_config_fun: fn ->
            %SowerClient.Config{
              policy: %{"direct" => %{actions: ["restart"], triggers: ["direct"]}}
            }
          end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "boot"))
    end

    test "clamps a wire action the local garden policy will not honour" do
      deployment = %Deployment{
        sid: "dep_wire_clamped",
        seed_deployments: [%{seed_deploy_with_identity("seed_w2") | action: "restart"}]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          garden_config_fun: fn ->
            %SowerClient.Config{
              policy: %{"direct" => %{actions: ["activate"], triggers: ["direct"]}}
            }
          end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "switch"))
      refute Enum.any?(logged_lines, &(&1 =~ "boot"))
    end

    test "stages when the local garden policy permits nothing right now" do
      deployment = %Deployment{
        sid: "dep_wire_staged",
        seed_deployments: [%{seed_deploy_with_identity("seed_w3") | action: "restart"}]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          garden_config_fun: fn ->
            %SowerClient.Config{
              policy: %{
                "closed" => %{
                  actions: ["activate"],
                  triggers: ["direct"],
                  window: %{days: [], time_start: "00:00", time_end: "23:59"}
                }
              }
            }
          end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "activation not permitted"))
    end

    test "ignores the garden policy when no wire action is carried" do
      deployment = %Deployment{
        sid: "dep_wire_absent",
        seed_deployments: [seed_deploy_with_identity("seed_w4")]
      }

      logged_lines =
        capture_seed_result_lines(deployment,
          find_subscription_fun: fn _ ->
            %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}
          end,
          garden_config_fun: fn ->
            %SowerClient.Config{
              policy: %{"direct" => %{actions: ["stage"], triggers: ["direct"]}}
            }
          end
        )

      assert Enum.any?(logged_lines, &(&1 =~ "[garden]" and &1 =~ "boot"))
    end
  end

  describe "direct deployment reboot" do
    test "restarts after boot activation when the subscription forbids restart or is absent" do
      for subscription <- [
            %Subscription{seed_type: "nixos", policy: [%{actions: ["activate"]}]},
            nil
          ] do
        assert run_reboot_deployment("restart", ["restart"], subscription) == :success
        assert_received {:activated, "boot"}
        assert_received {:rebooted, [reason: "direct_restart"]}
      end
    end

    test "explicit restart reboots even when system profile links have not changed" do
      assert run_reboot_deployment("restart", ["restart"], nil,
               read_link_fun: fn _ -> {:ok, "/nix/store/current-system"} end
             ) == :success

      assert_received {:activated, "boot"}
      assert_received {:rebooted, [reason: "direct_restart"]}
    end

    test "activate never inherits restart permission from a subscription" do
      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}

      assert run_reboot_deployment("activate", ["restart"], subscription) == :success
      assert_received {:activated, "switch"}
      refute_received {:rebooted, _}
    end

    test "locally clamped restart cannot reboot through subscription permissions" do
      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}

      assert run_reboot_deployment("restart", ["activate"], subscription) == :success
      assert_received {:activated, "switch"}
      refute_received {:rebooted, _}

      assert run_reboot_deployment("restart", ["stage"], subscription) == :success
      refute_received {:activated, _}
      refute_received {:rebooted, _}
    end

    test "a closed local policy window prevents activation and reboot" do
      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}

      assert run_reboot_deployment("restart", ["restart"], subscription,
               garden_config_fun: fn ->
                 %SowerClient.Config{
                   policy: %{
                     "closed" => %{
                       actions: ["restart"],
                       window: %{days: [], time_start: "00:00", time_end: "23:59"}
                     }
                   }
                 }
               end
             ) == :success

      refute_received {:activated, _}
      refute_received {:rebooted, _}
    end

    test "uses the action executed before local policy changes during activation" do
      policy = start_supervised!({Agent, fn -> ["restart"] end})
      test_pid = self()

      assert run_reboot_deployment("restart", ["restart"], nil,
               garden_config_fun: fn ->
                 %SowerClient.Config{
                   policy: %{"direct" => %{actions: Agent.get(policy, & &1)}}
                 }
               end,
               activate_seed_fun: fn _seed, mode ->
                 send(test_pid, {:activated, mode})
                 Agent.update(policy, fn _ -> ["activate"] end)
                 {:ok, ["activated"]}
               end
             ) == :success

      assert_received {:activated, "boot"}
      assert_received {:rebooted, [reason: "direct_restart"]}
    end

    test "failed direct activation or realization skips reboot" do
      assert run_reboot_deployment("restart", ["restart"], nil,
               activate_seed_fun: fn _, _ -> {:error, 1, ["failed activation"]} end
             ) == :failure

      refute_received {:rebooted, _}

      assert run_reboot_deployment("restart", ["restart"], nil,
               realize_seed_fun: fn sd ->
                 {:error, :failed_to_realize, sd, ["failed download"]}
               end
             ) == :failure

      refute_received {:activated, _}
      refute_received {:rebooted, _}
    end

    test "nil action preserves subscription reboot policy and system change detection" do
      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}

      assert run_reboot_deployment(nil, ["stage"], subscription) == :success
      assert_received {:activated, "boot"}
      assert_received {:rebooted, [reason: "system_changed"]}

      assert run_reboot_deployment(nil, ["restart"], subscription,
               read_link_fun: fn _ -> {:ok, "/nix/store/current-system"} end
             ) == :success

      assert_received {:activated, "boot"}
      refute_received {:rebooted, _}

      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["activate"]}]}
      assert run_reboot_deployment(nil, ["restart"], subscription) == :success
      assert_received {:activated, "switch"}
      refute_received {:rebooted, _}
    end
  end

  describe "authorized direct override" do
    test "restart bypasses a closed local policy and reboots after boot activation" do
      assert run_reboot_deployment("restart", ["stage"], nil,
               override: true,
               garden_config_fun: fn ->
                 %SowerClient.Config{
                   policy: %{
                     "closed" => %{
                       actions: ["restart"],
                       window: %{days: [], time_start: "00:00", time_end: "23:59"}
                     }
                   }
                 }
               end,
               read_link_fun: fn _ -> {:ok, "/nix/store/current-system"} end
             ) == :success

      assert_received {:activated, "boot"}
      assert_received {:rebooted, [reason: "direct_restart"]}
    end

    test "activate bypasses local denial without inheriting subscription restart" do
      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}

      assert run_reboot_deployment("activate", ["stage"], subscription, override: true) ==
               :success

      assert_received {:activated, "switch"}
      refute_received {:rebooted, _}
    end

    test "false override continues to clamp ordinary direct actions" do
      assert run_reboot_deployment("restart", ["activate"], nil, override: false) == :success
      assert_received {:activated, "switch"}
      refute_received {:rebooted, _}

      assert run_reboot_deployment("activate", ["stage"], nil, override: false) == :success
      refute_received {:activated, _}
      refute_received {:rebooted, _}
    end

    test "nil action retains subscription policy and conditional reboot despite override" do
      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["restart"]}]}

      assert run_reboot_deployment(nil, ["stage"], subscription, override: true) == :success
      assert_received {:activated, "boot"}
      assert_received {:rebooted, [reason: "system_changed"]}

      assert run_reboot_deployment(nil, ["stage"], subscription,
               override: true,
               read_link_fun: fn _ -> {:ok, "/nix/store/current-system"} end
             ) == :success

      assert_received {:activated, "boot"}
      refute_received {:rebooted, _}

      subscription = %Subscription{seed_type: "nixos", policy: [%{actions: ["stage"]}]}

      assert run_reboot_deployment(nil, ["restart"], subscription, override: true) == :success
      refute_received {:activated, _}
      refute_received {:rebooted, _}
    end

    test "activation failure prevents an override restart from rebooting" do
      test_pid = self()

      assert run_reboot_deployment("restart", ["stage"], nil,
               override: true,
               activate_seed_fun: fn _seed, mode ->
                 send(test_pid, {:activated, mode})
                 {:error, 1, ["activation denied"]}
               end
             ) == :failure

      assert_received {:activated, "boot"}
      refute_received {:rebooted, _}
    end

    test "override cannot execute an action unsupported by the seed type" do
      assert run_reboot_deployment("restart", ["stage"], nil,
               override: true,
               seed_type: "home-manager"
             ) == :failure

      refute_received {:activated, _}
      refute_received {:rebooted, _}
    end
  end

  defp run_reboot_deployment(action, garden_actions, subscription, opts \\ []) do
    deployment = %Deployment{
      sid: "dep_direct_reboot",
      seed_deployments: [
        %{
          seed_deploy_with_identity(
            "seed_direct_reboot",
            Keyword.get(opts, :seed_type, "nixos")
          )
          | action: action,
            override: Keyword.get(opts, :override, false)
        }
      ]
    }

    test_pid = self()
    find_subscription_fun = fn _ -> subscription end

    garden_config_fun =
      Keyword.get(opts, :garden_config_fun, fn ->
        %SowerClient.Config{
          policy: %{"direct" => %{actions: garden_actions, triggers: ["direct"]}}
        }
      end)

    Deployer.run_with_opts(deployment,
      upgrade_opts: [
        async_stream_fun: fn enumerable, func ->
          Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
        end,
        realize_seed_fun: Keyword.get(opts, :realize_seed_fun, fn sd -> {:ok, sd, []} end),
        find_subscription_fun: find_subscription_fun,
        garden_config_fun: garden_config_fun,
        activate_seed_fun:
          Keyword.get(opts, :activate_seed_fun, fn _seed, mode ->
            send(test_pid, {:activated, mode})
            {:ok, ["activated"]}
          end),
        report_seed_status_fun: fn _, _, _ -> :ok end,
        report_seed_result_fun: fn _, _, _, _ -> :ok end
      ],
      reboot_opts: [
        find_subscription_fun: find_subscription_fun,
        garden_config_fun: garden_config_fun,
        read_link_fun:
          Keyword.get(opts, :read_link_fun, fn
            "/nix/var/nix/profiles/system" -> {:ok, "/nix/store/new-system"}
            _ -> {:ok, "/nix/store/current-system"}
          end),
        reboot_fun: fn reboot_opts ->
          send(test_pid, {:rebooted, reboot_opts})
          {:ok, ["rebooting"]}
        end,
        activation_enabled_fun: fn -> true end
      ]
    )
  end

  defp capture_seed_result_lines(%Deployment{} = deployment, opts \\ []) do
    test_pid = self()

    capture_log(fn ->
      Deployer.upgrade(deployment,
        async_stream_fun: fn enumerable, func ->
          Enum.map(enumerable, fn item -> {:ok, func.(item)} end)
        end,
        realize_seed_fun: Keyword.get(opts, :realize_seed_fun, fn sd -> {:ok, sd, []} end),
        find_subscription_fun:
          Keyword.get(opts, :find_subscription_fun, fn _ -> %Subscription{} end),
        activate_seed_fun:
          Keyword.get(opts, :activate_seed_fun, fn _seed, _profile ->
            {:ok, ["activation output"]}
          end),
        report_seed_status_fun: fn _, _, _ -> :ok end,
        garden_config_fun: Keyword.get(opts, :garden_config_fun, fn -> %SowerClient.Config{} end),
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

  defp seed_deploy(subscription_sid, seed_type) do
    %SeedDeployment{
      subscription_sid: subscription_sid,
      seed: %Seed{seed_type: seed_type}
    }
  end

  defp seed_deploy_with_identity(seed_sid, seed_type \\ "nixos") do
    %SeedDeployment{
      subscription_sid: "sub_#{seed_sid}",
      seed: %Seed{
        sid: seed_sid,
        name: "seed-#{seed_sid}",
        seed_type: seed_type,
        artifact: "/nix/store/#{seed_sid}"
      }
    }
  end
end
