defmodule Garden.AdminTest do
  use ExUnit.Case, async: false

  alias SowerClient.Admin.{Deploy, Reload, Reregister, Status, StatusReport}

  describe "handle/1" do
    test "deploy selects the same subscription for default waiting and enqueue-only" do
      storage = Garden.Storage.read()
      on_exit(fn -> Garden.Storage.write(storage) end)

      sub = %SowerClient.Orchestration.Subscription{
        sid: "sub-1",
        name: "host",
        seed_name: "host",
        seed_type: "nixos"
      }

      Garden.Storage.put(:subscriptions, [sub])

      for selector <- [%{sid: sub.sid}, %{seed_type: sub.seed_type}] do
        command = Deploy.cast!(selector)
        assert {:wait, ^sub, ^command} = Garden.Admin.handle(command)

        assert {:ok, "deployment enqueued"} =
                 Garden.Admin.handle(%{command | wait: false})
      end
    end

    test "reload requests a reload and reports back" do
      on_exit(fn -> Garden.take_pending_reload() end)

      assert {:ok, "reload requested"} = Garden.Admin.handle(%Reload{})
      assert Garden.take_pending_reload() == true
    end

    test "status reports the garden version" do
      assert {:status, %StatusReport{} = report} = Garden.Admin.handle(%Status{})
      assert report.version == to_string(Application.spec(:garden, :vsn))
      assert report.active_deployments == []
      assert report.credentials_rejected_at == nil
      assert report.pending_deployments == nil
    end

    test "status surfaces a persisted credential rejection" do
      storage = Garden.Storage.read()
      on_exit(fn -> Garden.Storage.write(storage) end)

      Garden.Storage.put(:credentials_rejected_at, "2026-08-29T00:00:00Z")

      assert {:status, %StatusReport{} = report} = Garden.Admin.handle(%Status{})
      assert report.credentials_rejected_at == "2026-08-29T00:00:00Z"
    end

    test "reregister reports when the garden socket is not running" do
      assert {:error, message} = Garden.Admin.handle(%Reregister{})
      assert message =~ "not running"
    end

    test "deploy without a seed_type or sid is an error" do
      assert {:error, message} = Garden.Admin.handle(%Deploy{})
      assert message =~ "seed_type or sid"
    end
  end
end
