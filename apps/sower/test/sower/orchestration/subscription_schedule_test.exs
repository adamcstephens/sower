defmodule Sower.Orchestration.SubscriptionScheduleTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.Subscription

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    garden = garden_fixture(%{org_id: org.org_id})
    seed = seed_fixture(%{org_id: org.org_id, name: "test-seed", seed_type: "nixos"})

    %{org: org, garden: garden, seed: seed}
  end

  describe "catch_up_overdue_schedules/2" do
    test "subscription with schedule and no prior deployments is overdue",
         %{garden: garden} do
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "test-seed",
        seed_type: "nixos",
        schedule: "0 3 * * *"
      })

      overdue = Subscription.catch_up_overdue_schedules(garden)

      assert length(overdue) == 1
    end

    test "subscription with schedule and recent successful deployment is not overdue",
         %{garden: garden, seed: seed} do
      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "test-seed",
          seed_type: "nixos",
          schedule: "0 3 * * *"
        })

      # Deploy 30 minutes ago — within the current schedule window
      deployed_at = DateTime.add(DateTime.utc_now(), -30 * 60, :second)

      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [sub],
        state: :completed,
        result: :success,
        deployed_at: DateTime.truncate(deployed_at, :second)
      })

      # Set now to 30 minutes after the most recent 3am UTC
      {:ok, cron} = Crontab.CronExpression.Parser.parse("0 3 * * *")
      previous_run = Crontab.Scheduler.get_previous_run_date!(cron, NaiveDateTime.utc_now())
      now = DateTime.from_naive!(previous_run, "Etc/UTC") |> DateTime.add(30 * 60, :second)

      overdue = Subscription.catch_up_overdue_schedules(garden, now: now)

      assert overdue == []
    end

    test "subscription with deployment older than last cron run is overdue",
         %{garden: garden, seed: seed} do
      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "test-seed",
          seed_type: "nixos",
          schedule: "* * * * *"
        })

      # Deploy 2 minutes ago — the every-minute schedule has fired since
      deployed_at =
        DateTime.utc_now()
        |> DateTime.add(-120, :second)
        |> DateTime.truncate(:second)

      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [sub],
        state: :completed,
        result: :success,
        deployed_at: deployed_at
      })

      overdue = Subscription.catch_up_overdue_schedules(garden)

      assert length(overdue) == 1
      assert hd(overdue).sid == sub.sid
    end

    test "subscription without schedule is never overdue",
         %{garden: garden} do
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "test-seed",
        seed_type: "nixos",
        schedule: nil
      })

      overdue = Subscription.catch_up_overdue_schedules(garden)

      assert overdue == []
    end

    test "failed deployments don't count as successful",
         %{garden: garden, seed: seed} do
      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "test-seed",
          seed_type: "nixos",
          schedule: "* * * * *"
        })

      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [sub],
        state: :completed,
        result: :failure,
        deployed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      overdue = Subscription.catch_up_overdue_schedules(garden)

      assert length(overdue) == 1
    end

    test "stale deployments don't count as successful",
         %{garden: garden, seed: seed} do
      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "test-seed",
          seed_type: "nixos",
          schedule: "* * * * *"
        })

      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [sub],
        state: :stale,
        result: :failure,
        deployed_at: DateTime.truncate(DateTime.utc_now(), :second)
      })

      overdue = Subscription.catch_up_overdue_schedules(garden)

      assert length(overdue) == 1
    end

    test "timezone-aware evaluation",
         %{garden: garden} do
      # Schedule at 3am in America/New_York
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "test-seed",
        seed_type: "nixos",
        schedule: "0 3 * * *",
        timezone: "America/New_York"
      })

      # Set now to 4am ET (which is 8am or 9am UTC depending on DST)
      # 3am ET has passed, so the subscription should be overdue
      et_now =
        DateTime.utc_now()
        |> DateTime.shift_zone!("America/New_York")

      # Build a time that is 4am ET today
      four_am_et =
        et_now
        |> DateTime.to_date()
        |> then(&DateTime.new!(&1, ~T[04:00:00], "America/New_York"))
        |> DateTime.shift_zone!("Etc/UTC")

      overdue = Subscription.catch_up_overdue_schedules(garden, now: four_am_et)

      assert length(overdue) == 1
    end
  end
end
