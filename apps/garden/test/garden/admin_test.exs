defmodule Garden.AdminTest do
  use ExUnit.Case, async: true

  alias SowerClient.Admin.{Deploy, Reload, Status, StatusReport}

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
    end

    test "deploy without a seed_type or sid is an error" do
      assert {:error, message} = Garden.Admin.handle(%Deploy{})
      assert message =~ "seed_type or sid"
    end
  end
end
