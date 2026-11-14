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

        no_wait = %{command | wait: false}
        assert {:wait, ^sub, ^no_wait} = Garden.Admin.handle(no_wait)
      end
    end

    test "reload requests a reload and reports back" do
      on_exit(fn -> Garden.take_pending_reload() end)

      assert {:ok, "reload requested"} = Garden.Admin.handle(%Reload{})
      assert Garden.take_pending_reload() == true
    end

    test "status reports the garden version without a configured server endpoint" do
      config = Garden.Config.get()
      on_exit(fn -> Application.put_env(:garden, :config, config) end)
      Application.put_env(:garden, :config, %SowerClient.Config{endpoint: nil})

      assert {:status, %StatusReport{} = report} = Garden.Admin.handle(%Status{})
      assert report.version == to_string(Application.spec(:garden, :vsn))
      assert report.active_deployments == []
      assert report.running_deployments == []
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

    test "bare deploy observes pending work, including force and no-wait" do
      for attrs <- [%{}, %{force: true}, %{wait: false}] do
        command = Deploy.cast!(attrs)
        assert {:wait, nil, ^command} = Garden.Admin.handle(command)
      end
    end
  end
end
