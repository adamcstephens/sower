defmodule Garden.SchedulerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Garden.Scheduler
  alias SowerClient.Orchestration.Subscription

  defp start_cooldown(_context) do
    {:ok, agent} = Agent.start_link(fn -> %{} end)
    cooldown_seconds = 60

    check_cooldown = fn key ->
      Agent.get_and_update(agent, fn state ->
        now = System.monotonic_time(:second)

        case Map.get(state, key) do
          last when is_integer(last) and now - last < cooldown_seconds ->
            {{:cooldown, now - last}, state}

          _ ->
            {:ok, Map.put(state, key, now)}
        end
      end)
    end

    %{check_cooldown: check_cooldown}
  end

  describe "deploy_if_not_cooled_down/3" do
    setup [:start_cooldown]

    test "deploys on first call", %{check_cooldown: check_cooldown} do
      sid = "sub_first_#{System.unique_integer([:positive])}"
      sub = %Subscription{sid: sid, seed_name: "test", seed_type: "nixos"}
      test_pid = self()

      Scheduler.deploy_if_not_cooled_down(sid, "0 3",
        deploy_fun: fn deployed_sub ->
          send(test_pid, {:deployed, deployed_sub})
        end,
        check_cooldown: check_cooldown,
        read_subscriptions: fn -> [sub] end
      )

      assert_received {:deployed, ^sub}
    end

    test "skips duplicate calls within cooldown window", %{check_cooldown: check_cooldown} do
      sid = "sub_dup_#{System.unique_integer([:positive])}"
      sub = %Subscription{sid: sid, seed_name: "test", seed_type: "nixos"}
      test_pid = self()

      opts = [
        deploy_fun: fn _sub -> send(test_pid, :deployed) end,
        check_cooldown: check_cooldown,
        read_subscriptions: fn -> [sub] end
      ]

      Scheduler.deploy_if_not_cooled_down(sid, "0 3", opts)
      assert_received :deployed

      result = Scheduler.deploy_if_not_cooled_down(sid, "0 3", opts)

      refute_received :deployed
      assert result == :skipped
    end

    test "different subscriptions are independent", %{check_cooldown: check_cooldown} do
      sid_a = "sub_a_#{System.unique_integer([:positive])}"
      sid_b = "sub_b_#{System.unique_integer([:positive])}"
      sub_a = %Subscription{sid: sid_a, seed_name: "host-a", seed_type: "nixos"}
      sub_b = %Subscription{sid: sid_b, seed_name: "host-b", seed_type: "nixos"}
      test_pid = self()

      opts = fn subs ->
        [
          deploy_fun: fn sub -> send(test_pid, {:deployed, sub.sid}) end,
          check_cooldown: check_cooldown,
          read_subscriptions: fn -> subs end
        ]
      end

      Scheduler.deploy_if_not_cooled_down(sid_a, "0 3", opts.([sub_a]))
      assert_received {:deployed, ^sid_a}

      Scheduler.deploy_if_not_cooled_down(sid_b, "0 3", opts.([sub_b]))
      assert_received {:deployed, ^sid_b}
    end

    test "warns when subscription not found in storage", %{check_cooldown: check_cooldown} do
      sid = "sub_gone_#{System.unique_integer([:positive])}"
      test_pid = self()

      log =
        capture_log(fn ->
          Scheduler.deploy_if_not_cooled_down(sid, "0 3",
            deploy_fun: fn _sub -> send(test_pid, :deployed) end,
            check_cooldown: check_cooldown,
            read_subscriptions: fn -> [] end
          )
        end)

      refute_received :deployed
      assert log =~ "Subscription not found for scheduled deployment"
    end

    test "skips when policy denies scheduled trigger", %{check_cooldown: check_cooldown} do
      sid = "sub_denied_#{System.unique_integer([:positive])}"

      sub = %Subscription{
        sid: sid,
        seed_name: "test",
        seed_type: "nixos",
        policy: [%{actions: ["activate"], triggers: ["manual"]}]
      }

      test_pid = self()

      log =
        capture_log([level: :info], fn ->
          Scheduler.deploy_if_not_cooled_down(sid, "0 3",
            deploy_fun: fn _sub -> send(test_pid, :deployed) end,
            check_cooldown: check_cooldown,
            read_subscriptions: fn -> [sub] end
          )
        end)

      refute_received :deployed
      assert log =~ "Scheduled deploy denied by policy"
    end

    test "rapid-fire calls only deploy once", %{check_cooldown: check_cooldown} do
      sid = "sub_rapid_#{System.unique_integer([:positive])}"
      sub = %Subscription{sid: sid, seed_name: "test", seed_type: "nixos"}
      test_pid = self()

      opts = [
        deploy_fun: fn _sub -> send(test_pid, :deployed) end,
        check_cooldown: check_cooldown,
        read_subscriptions: fn -> [sub] end
      ]

      # Simulate Quantum catch-up firing 10 times in rapid succession
      for _ <- 1..10 do
        Scheduler.deploy_if_not_cooled_down(sid, "0 3", opts)
      end

      assert_received :deployed
      refute_received :deployed
    end
  end
end
