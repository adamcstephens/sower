defmodule Garden.AdminTest do
  use ExUnit.Case, async: true

  alias SowerClient.Admin.Request
  alias SowerClient.Admin.Status

  describe "handle/1" do
    test "reload requests a reload and reports back" do
      on_exit(fn -> Garden.take_pending_reload() end)

      assert {:ok, "reload requested"} = Garden.Admin.handle(%Request{id: "r", kind: "reload"})
      assert Garden.take_pending_reload() == true
    end

    test "status reports the garden version" do
      assert {:status, %Status{} = status} =
               Garden.Admin.handle(%Request{id: "s", kind: "status"})

      assert status.version == to_string(Application.spec(:garden, :vsn))
      assert status.active_deployments == []
    end

    test "deploy without a seed_type or sid is an error" do
      assert {:error, message} = Garden.Admin.handle(%Request{id: "d", kind: "deploy"})
      assert message =~ "seed_type or sid"
    end
  end
end
