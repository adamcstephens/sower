defmodule SowerClient.Orchestration.Subscription.PolicyTest do
  use ExUnit.Case, async: true

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
end
