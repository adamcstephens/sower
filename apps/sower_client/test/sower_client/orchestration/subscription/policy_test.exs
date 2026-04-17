defmodule SowerClient.Orchestration.Subscription.PolicyTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SowerClient.Orchestration.Subscription.Policy

  # Wednesday 2026-04-15 at 14:00 UTC
  @now DateTime.from_naive!(~N[2026-04-15 14:00:00], "Etc/UTC")

  describe "evaluate/5 — basic allow/deny" do
    test "allows action when rule matches" do
      rules = [%{actions: ["activate"], triggers: ["manual"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "denies when no rule matches trigger" do
      rules = [%{actions: ["activate"], triggers: ["scheduled"]}]
      assert :deny = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "denies when no rule matches action for seed type" do
      rules = [%{actions: ["restart"], triggers: ["manual"]}]
      assert :deny = Policy.evaluate(rules, :manual, @now, "home-manager")
    end

    test "allows stage action" do
      rules = [%{actions: ["stage"], triggers: ["manual"]}]
      assert {:allow, :stage} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "allows restart action for nixos" do
      rules = [%{actions: ["restart"], triggers: ["manual"]}]
      assert {:allow, :restart} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "allows restart action for nix-darwin" do
      rules = [%{actions: ["restart"], triggers: ["manual"]}]
      assert {:allow, :restart} = Policy.evaluate(rules, :manual, @now, "nix-darwin")
    end
  end

  describe "evaluate/5 — trigger matching" do
    test "nil triggers matches any trigger" do
      rules = [%{actions: ["activate"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
      assert {:allow, :activate} = Policy.evaluate(rules, :scheduled, @now, "nixos")
      assert {:allow, :activate} = Policy.evaluate(rules, :realtime, @now, "nixos")
    end

    test "matches specific trigger" do
      rules = [%{actions: ["activate"], triggers: ["realtime"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :realtime, @now, "nixos")
      assert :deny = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "matches multiple triggers" do
      rules = [%{actions: ["activate"], triggers: ["manual", "scheduled"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
      assert {:allow, :activate} = Policy.evaluate(rules, :scheduled, @now, "nixos")
      assert :deny = Policy.evaluate(rules, :realtime, @now, "nixos")
    end
  end

  describe "evaluate/5 — disruption hierarchy" do
    test "returns highest permitted action" do
      rules = [
        %{actions: ["stage"], triggers: ["manual"]},
        %{actions: ["activate"], triggers: ["manual"]},
        %{actions: ["restart"], triggers: ["manual"]}
      ]

      assert {:allow, :restart} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "returns activate when restart not permitted" do
      rules = [
        %{actions: ["stage"], triggers: ["manual"]},
        %{actions: ["activate"], triggers: ["manual"]}
      ]

      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "returns stage when only stage permitted" do
      rules = [%{actions: ["stage"], triggers: ["manual"]}]
      assert {:allow, :stage} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "single rule with multiple actions returns highest" do
      rules = [%{actions: ["stage", "activate", "restart"], triggers: ["manual"]}]
      assert {:allow, :restart} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "skips unsupported actions for seed type" do
      rules = [%{actions: ["stage", "activate", "restart"], triggers: ["manual"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "home-manager")
    end
  end

  describe "evaluate/5 — default policy" do
    test "applies default policy when rules is nil" do
      assert {:allow, :activate} = Policy.evaluate(nil, :manual, @now, "nixos")
    end

    test "applies default policy when rules is empty list" do
      assert {:allow, :activate} = Policy.evaluate([], :manual, @now, "nixos")
    end

    test "default policy allows manual trigger" do
      assert {:allow, :activate} = Policy.evaluate([], :manual, @now, "nixos")
    end

    test "default policy allows scheduled trigger" do
      assert {:allow, :activate} = Policy.evaluate([], :scheduled, @now, "nixos")
    end

    test "default policy allows poll_on_connect trigger" do
      assert {:allow, :activate} = Policy.evaluate([], :poll_on_connect, @now, "nixos")
    end

    test "default policy denies realtime trigger" do
      assert :deny = Policy.evaluate([], :realtime, @now, "nixos")
    end

    test "default policy does not allow restart" do
      # Default allows activate, not restart, so even manual gets activate
      assert {:allow, :activate} = Policy.evaluate([], :manual, @now, "nixos")
    end
  end

  describe "evaluate/5 — confirm flag" do
    test "returns confirm when rule has confirm: true" do
      rules = [%{actions: ["activate"], triggers: ["manual"], confirm: true}]
      assert {:confirm, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "confirm wins when multiple rules match and any has confirm" do
      rules = [
        %{actions: ["activate"], triggers: ["manual"]},
        %{actions: ["activate"], triggers: ["manual"], confirm: true}
      ]

      assert {:confirm, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "no confirm when all matching rules have confirm: false" do
      rules = [
        %{actions: ["activate"], triggers: ["manual"], confirm: false},
        %{actions: ["activate"], triggers: ["manual"]}
      ]

      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end
  end

  describe "evaluate/5 — window matching" do
    test "allows when within window" do
      # Wednesday at 14:00 UTC, window is weekdays 09:00-17:00
      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{
            days: ["mon", "tue", "wed", "thu", "fri"],
            time_start: "09:00",
            time_end: "17:00"
          }
        }
      ]

      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "denies when outside window time" do
      # Wednesday at 14:00 UTC, window is 02:00-04:00
      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{
            days: ["mon", "tue", "wed", "thu", "fri"],
            time_start: "02:00",
            time_end: "04:00"
          }
        }
      ]

      assert :deny = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "denies when outside window day" do
      # Wednesday at 14:00 UTC, window is weekends only
      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["sat", "sun"], time_start: "09:00", time_end: "17:00"}
        }
      ]

      assert :deny = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "allows with no window (always matches)" do
      rules = [%{actions: ["activate"], triggers: ["manual"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "uses subscription timezone for window evaluation" do
      # Wednesday at 14:00 UTC = Wednesday at 10:00 EDT (America/New_York)
      # Window is 09:00-11:00 in New York time — should match
      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["wed"], time_start: "09:00", time_end: "11:00"}
        }
      ]

      assert {:allow, :activate} =
               Policy.evaluate(rules, :manual, @now, "nixos", "America/New_York")
    end

    test "subscription timezone shifts day boundary" do
      # Wednesday at 14:00 UTC = Thursday at 00:00 in UTC+10
      # Window is Thursday 00:00-02:00 — should match
      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["thu"], time_start: "00:00", time_end: "02:00"}
        }
      ]

      assert {:allow, :activate} =
               Policy.evaluate(rules, :manual, @now, "nixos", "Australia/Brisbane")
    end
  end

  describe "evaluate/5 — overnight window spans" do
    test "allows during opening portion of overnight window" do
      # Friday at 23:00 UTC, window is Fri 22:00-06:00
      friday_23 = DateTime.from_naive!(~N[2026-04-17 23:00:00], "Etc/UTC")

      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["fri"], time_start: "22:00", time_end: "06:00"}
        }
      ]

      assert {:allow, :activate} = Policy.evaluate(rules, :manual, friday_23, "nixos")
    end

    test "allows during closing portion of overnight window" do
      # Saturday at 03:00 UTC, window is Fri 22:00-06:00
      saturday_03 = DateTime.from_naive!(~N[2026-04-18 03:00:00], "Etc/UTC")

      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["fri"], time_start: "22:00", time_end: "06:00"}
        }
      ]

      assert {:allow, :activate} = Policy.evaluate(rules, :manual, saturday_03, "nixos")
    end

    test "denies outside overnight window" do
      # Friday at 12:00 UTC, window is Fri 22:00-06:00
      friday_12 = DateTime.from_naive!(~N[2026-04-17 12:00:00], "Etc/UTC")

      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["fri"], time_start: "22:00", time_end: "06:00"}
        }
      ]

      assert :deny = Policy.evaluate(rules, :manual, friday_12, "nixos")
    end

    test "denies on wrong day for overnight window closing portion" do
      # Sunday at 03:00 UTC, window is Fri 22:00-06:00 (only Fri->Sat)
      sunday_03 = DateTime.from_naive!(~N[2026-04-19 03:00:00], "Etc/UTC")

      rules = [
        %{
          actions: ["activate"],
          triggers: ["manual"],
          window: %{days: ["fri"], time_start: "22:00", time_end: "06:00"}
        }
      ]

      assert :deny = Policy.evaluate(rules, :manual, sunday_03, "nixos")
    end
  end

  describe "evaluate/5 — seed type validation" do
    test "nixos supports all actions" do
      rules = [%{actions: ["stage", "activate", "restart"]}]
      assert {:allow, :restart} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "nix-darwin supports all actions" do
      rules = [%{actions: ["stage", "activate", "restart"]}]
      assert {:allow, :restart} = Policy.evaluate(rules, :manual, @now, "nix-darwin")
    end

    test "home-manager supports stage and activate only" do
      rules = [%{actions: ["stage", "activate", "restart"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "home-manager")
    end

    test "service supports stage and activate only" do
      rules = [%{actions: ["stage", "activate", "restart"]}]
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "service")
    end

    test "unknown seed type denies all" do
      rules = [%{actions: ["stage", "activate", "restart"]}]
      assert :deny = Policy.evaluate(rules, :manual, @now, "unknown")
    end

    test "logs warning for unsupported action on seed type" do
      rules = [%{actions: ["restart", "activate"]}]

      log =
        capture_log(fn ->
          Policy.evaluate(rules, :manual, @now, "home-manager")
        end)

      assert log =~ "unsupported action"
      assert log =~ "restart"
      assert log =~ "home-manager"
    end
  end

  describe "evaluate/5 — string key maps" do
    test "works with string-keyed maps" do
      rules = [
        %{
          "actions" => ["activate"],
          "triggers" => ["manual"],
          "confirm" => false,
          "window" => %{
            "days" => ["wed"],
            "time_start" => "09:00",
            "time_end" => "17:00"
          }
        }
      ]

      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end

    test "confirm works with string keys" do
      rules = [%{"actions" => ["activate"], "triggers" => ["manual"], "confirm" => true}]
      assert {:confirm, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")
    end
  end

  describe "evaluate/5 — complex scenarios from spec" do
    test "manual apply anytime, reboot only 2-4am" do
      rules = [
        %{actions: ["activate"], triggers: ["manual"]},
        %{
          actions: ["restart"],
          window: %{
            days: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
            time_start: "02:00",
            time_end: "04:00"
          }
        }
      ]

      # At 14:00 manual → activate (restart window not open)
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "nixos")

      # At 03:00 manual → restart (both rules match, restart is highest)
      at_3am = DateTime.from_naive!(~N[2026-04-15 03:00:00], "Etc/UTC")
      assert {:allow, :restart} = Policy.evaluate(rules, :manual, at_3am, "nixos")

      # At 14:00 scheduled → deny (no scheduled trigger in any rule)
      assert :deny = Policy.evaluate(rules, :scheduled, @now, "nixos")
    end

    test "staging only for service seed type" do
      rules = [%{actions: ["stage"], triggers: ["scheduled", "realtime"]}]

      assert {:allow, :stage} = Policy.evaluate(rules, :scheduled, @now, "service")
      assert {:allow, :stage} = Policy.evaluate(rules, :realtime, @now, "service")
      assert :deny = Policy.evaluate(rules, :manual, @now, "service")
    end

    test "everything allowed with manual confirmation for reboot" do
      rules = [
        %{actions: ["stage", "activate"]},
        %{actions: ["restart"], confirm: true}
      ]

      # manual → confirm restart (highest action, but requires confirmation)
      assert {:confirm, :restart} = Policy.evaluate(rules, :manual, @now, "nixos")

      # For home-manager → allow activate (restart not supported)
      assert {:allow, :activate} = Policy.evaluate(rules, :manual, @now, "home-manager")
    end
  end

  describe "from_legacy/1" do
    test "returns a map keyed by rule name" do
      sub = %{reboot_policy: "never", allow_realtime: false, poll_on_connect: false, window: nil}
      policy = Policy.from_legacy(sub)

      assert is_map(policy)
      assert Map.has_key?(policy, "default")
    end

    test "basic subscription with defaults" do
      sub = %{reboot_policy: "never", allow_realtime: false, poll_on_connect: false, window: nil}
      %{"default" => rule} = Policy.from_legacy(sub)

      assert rule.actions == ["stage", "activate"]
      assert rule.triggers == ["manual", "scheduled"]
      refute Map.has_key?(rule, :window)
    end

    test "reboot_policy always adds restart action" do
      sub = %{reboot_policy: "always", allow_realtime: false, poll_on_connect: false, window: nil}
      %{"default" => rule} = Policy.from_legacy(sub)

      assert "restart" in rule.actions
    end

    test "reboot_policy when-required adds restart action" do
      sub = %{
        reboot_policy: "when-required",
        allow_realtime: false,
        poll_on_connect: false,
        window: nil
      }

      %{"default" => rule} = Policy.from_legacy(sub)

      assert "restart" in rule.actions
    end

    test "allow_realtime adds realtime trigger" do
      sub = %{reboot_policy: "never", allow_realtime: true, poll_on_connect: false, window: nil}
      %{"default" => rule} = Policy.from_legacy(sub)

      assert "realtime" in rule.triggers
    end

    test "poll_on_connect adds poll_on_connect trigger" do
      sub = %{reboot_policy: "never", allow_realtime: false, poll_on_connect: true, window: nil}
      %{"default" => rule} = Policy.from_legacy(sub)

      assert "poll_on_connect" in rule.triggers
    end

    test "window is attached to the rule" do
      window = %{
        days: ["mon", "fri"],
        time_start: "09:00",
        time_end: "17:00",
        tz: "America/New_York"
      }

      sub = %{
        reboot_policy: "never",
        allow_realtime: false,
        poll_on_connect: false,
        window: window
      }

      %{"default" => rule} = Policy.from_legacy(sub)

      assert rule.window.days == ["mon", "fri"]
      assert rule.window.time_start == "09:00"
      assert rule.window.time_end == "17:00"
      assert rule.window.tz == "America/New_York"
    end

    test "full legacy subscription converts correctly" do
      sub = %{
        reboot_policy: "always",
        allow_realtime: true,
        poll_on_connect: true,
        window: %{days: ["mon"], time_start: "02:00", time_end: "06:00", tz: "Etc/UTC"}
      }

      %{"default" => rule} = Policy.from_legacy(sub)

      assert rule.actions == ["stage", "activate", "restart"]
      assert "manual" in rule.triggers
      assert "scheduled" in rule.triggers
      assert "poll_on_connect" in rule.triggers
      assert "realtime" in rule.triggers
      assert rule.window.days == ["mon"]
    end

    test "works with string-keyed maps" do
      sub = %{
        "reboot_policy" => "always",
        "allow_realtime" => true,
        "poll_on_connect" => false,
        "window" => nil
      }

      %{"default" => rule} = Policy.from_legacy(sub)

      assert "restart" in rule.actions
      assert "realtime" in rule.triggers
    end

    test "from_legacy poll_on_connect round-trips through evaluate" do
      sub = %{reboot_policy: "never", allow_realtime: false, poll_on_connect: true, window: nil}
      policy = Policy.from_legacy(sub)

      now = DateTime.from_naive!(~N[2026-04-15 14:00:00], "Etc/UTC")
      assert {:allow, :activate} = Policy.evaluate(policy, :poll_on_connect, now, "nixos")
    end

    test "from_legacy without poll_on_connect denies poll_on_connect trigger" do
      sub = %{reboot_policy: "never", allow_realtime: false, poll_on_connect: false, window: nil}
      policy = Policy.from_legacy(sub)

      now = DateTime.from_naive!(~N[2026-04-15 14:00:00], "Etc/UTC")
      assert :deny = Policy.evaluate(policy, :poll_on_connect, now, "nixos")
    end
  end

  describe "has_realtime_trigger?/1" do
    test "returns true when realtime is in triggers" do
      rules = [%{actions: ["activate"], triggers: ["realtime"]}]
      assert Policy.has_realtime_trigger?(rules)
    end

    test "returns true when triggers is nil (matches all)" do
      rules = [%{actions: ["activate"]}]
      assert Policy.has_realtime_trigger?(rules)
    end

    test "returns false when realtime not in any triggers" do
      rules = [%{actions: ["activate"], triggers: ["manual", "scheduled"]}]
      refute Policy.has_realtime_trigger?(rules)
    end

    test "returns true with default policy (no realtime)" do
      # Default policy has manual, scheduled, poll_on_connect — no realtime
      refute Policy.has_realtime_trigger?([])
    end

    test "works with map-format policy" do
      rules = %{"rt_rule" => %{actions: ["activate"], triggers: ["realtime"]}}
      assert Policy.has_realtime_trigger?(rules)
    end

    test "returns false with empty map" do
      refute Policy.has_realtime_trigger?(%{})
    end
  end

  describe "evaluate/5 — map-format policy" do
    test "evaluates map-format policy" do
      policy = %{
        "manual_activate" => %{actions: ["activate"], triggers: ["manual"]},
        "reboot_window" => %{
          actions: ["restart"],
          window: %{
            days: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"],
            time_start: "02:00",
            time_end: "04:00"
          }
        }
      }

      assert {:allow, :activate} = Policy.evaluate(policy, :manual, @now, "nixos")
    end

    test "empty map uses default policy" do
      assert {:allow, :activate} = Policy.evaluate(%{}, :manual, @now, "nixos")
    end
  end

  describe "highest_permitted_action/4" do
    test "returns highest action permitted by any rule" do
      rules = [
        %{actions: ["activate"], triggers: ["manual"]},
        %{actions: ["restart"], triggers: ["scheduled"]}
      ]

      assert :restart = Policy.highest_permitted_action(rules, @now, "nixos")
    end

    test "respects window constraints" do
      rules = [
        %{actions: ["activate"]},
        %{
          actions: ["restart"],
          window: %{days: ["sat"], time_start: "02:00", time_end: "04:00"}
        }
      ]

      # Wednesday — restart window closed, activate is highest
      assert :activate = Policy.highest_permitted_action(rules, @now, "nixos")
    end

    test "returns restart when window is open" do
      # Friday at 23:00
      friday_23 = DateTime.from_naive!(~N[2026-04-17 23:00:00], "Etc/UTC")

      rules = [
        %{actions: ["activate"]},
        %{
          actions: ["restart"],
          window: %{days: ["fri"], time_start: "22:00", time_end: "06:00"}
        }
      ]

      assert :restart = Policy.highest_permitted_action(rules, friday_23, "nixos")
    end

    test "skips unsupported actions for seed type" do
      rules = [%{actions: ["restart", "activate", "stage"]}]

      assert :activate = Policy.highest_permitted_action(rules, @now, "home-manager")
    end

    test "returns nil when no actions permitted" do
      rules = [
        %{
          actions: ["activate"],
          window: %{days: ["sat"], time_start: "02:00", time_end: "04:00"}
        }
      ]

      # Wednesday — window closed, nothing permitted
      assert nil == Policy.highest_permitted_action(rules, @now, "nixos")
    end

    test "ignores triggers" do
      rules = [%{actions: ["restart"], triggers: ["manual"]}]

      # Triggers are ignored — restart is permitted
      assert :restart = Policy.highest_permitted_action(rules, @now, "nixos")
    end

    test "works with map-format policy" do
      policy = %{
        "activate_rule" => %{actions: ["activate"]},
        "restart_rule" => %{actions: ["restart"]}
      }

      assert :restart = Policy.highest_permitted_action(policy, @now, "nixos")
    end

    test "default policy returns activate" do
      assert :activate = Policy.highest_permitted_action([], @now, "nixos")
    end
  end
end
