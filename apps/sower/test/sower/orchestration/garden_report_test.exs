defmodule Sower.Orchestration.GardenReportTest do
  use Sower.DataCase, async: true

  alias Sower.Orchestration.Garden
  alias SowerClient.Orchestration.GardenReport

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    %{garden: garden_fixture(%{org_id: org.org_id})}
  end

  test "persists garden-declared policy and timezone", %{garden: garden} do
    report =
      GardenReport.cast!(%{
        version: "1.2.3",
        timezone: "America/Denver",
        policy: %{
          "direct_push" => %{
            "actions" => ["activate"],
            "triggers" => ["direct"],
            "window" => %{"days" => ["mon"], "time_start" => "09:00", "time_end" => "17:00"}
          }
        }
      })

    assert {:ok, updated} = Garden.update_garden_report(garden, report)

    assert updated.version == "1.2.3"
    assert updated.timezone == "America/Denver"
    assert [rule] = updated.policy
    assert rule.name == "direct_push"
    assert rule.actions == ["activate"]
    assert rule.triggers == ["direct"]
    assert rule.window.days == ["mon"]
  end

  test "a report without policy leaves the garden denying direct deploys", %{garden: garden} do
    report = GardenReport.cast!(%{version: "1.2.3"})

    assert {:ok, updated} = Garden.update_garden_report(garden, report)
    assert updated.policy == []
  end
end
