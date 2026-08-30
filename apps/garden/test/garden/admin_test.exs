defmodule Garden.AdminTest do
  use ExUnit.Case, async: false

  alias SowerClient.Admin.{Deploy, Reload, Reregister, Status, StatusReport}

  describe "handle/1" do
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
