defmodule Sower.Workers.DeploySubscriptionTest do
  use Sower.DataCase

  import Sower.AccountsFixtures
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  alias Sower.Workers.DeploySubscription

  setup do
    org = organization_fixture()
    Sower.Repo.put_org_id(org.org_id)
    %{org: org}
  end

  describe "run/2" do
    @tag :capture_log
    test "returns :ok when subscription not found" do
      assert :ok = DeploySubscription.run("sub_nonexistent")
    end

    test "returns :ok when subscription is outside window" do
      garden = garden_fixture()

      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          allow_realtime: true,
          window: %{
            days: ["mon"],
            time_start: "00:00",
            time_end: "00:01",
            tz: "Pacific/Kiritimati"
          }
        })

      assert :ok = DeploySubscription.run(sub.sid)
    end

    @tag :capture_log
    test "calls deploy function for subscription within window" do
      garden = garden_fixture()
      seed_fixture(%{name: "myhost", seed_type: "nixos"})

      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          allow_realtime: true
        })

      test_pid = self()

      deploy_fun = fn subscription, _opts ->
        send(test_pid, {:deployed, subscription.sid})
        {:ok, "req_test123", self()}
      end

      assert :ok = DeploySubscription.run(sub.sid, deploy_fun)
      assert_received {:deployed, sid}
      assert sid == sub.sid
    end

    @tag :capture_log
    test "returns error when deploy fails" do
      garden = garden_fixture()
      seed_fixture(%{name: "myhost", seed_type: "nixos"})

      sub =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: "myhost",
          seed_type: "nixos",
          allow_realtime: true
        })

      deploy_fun = fn _sub, _opts -> {:error, :connection_refused} end

      assert {:error, :connection_refused} = DeploySubscription.run(sub.sid, deploy_fun)
    end
  end
end
