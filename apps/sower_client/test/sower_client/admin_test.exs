defmodule SowerClient.AdminTest do
  use ExUnit.Case, async: true

  alias SowerClient.Admin
  alias SowerClient.Admin.{Deploy, Reload, Reply, Request, Status, StatusReport}

  describe "decode_request/1" do
    test "decodes a deploy envelope into a typed command" do
      assert {:ok, %Request{v: 1, id: "abc", message: %Deploy{} = deploy}} =
               Admin.decode_request(%{
                 "v" => 1,
                 "id" => "abc",
                 "kind" => "deploy",
                 "payload" => %{"seed_type" => "nixos", "force" => true}
               })

      assert deploy.seed_type == "nixos"
      assert deploy.force == true
    end

    test "decodes the field-less commands with no payload" do
      assert {:ok, %Request{message: %Reload{}}} =
               Admin.decode_request(%{"id" => "a", "kind" => "reload"})

      assert {:ok, %Request{message: %Status{}}} =
               Admin.decode_request(%{"id" => "a", "kind" => "status"})
    end

    test "defaults v and force" do
      assert {:ok, %Request{v: 1, message: %Deploy{force: false}}} =
               Admin.decode_request(%{"id" => "a", "kind" => "deploy"})
    end

    test "rejects an unknown kind" do
      assert {:error, {:unknown_kind, "frobnicate"}} =
               Admin.decode_request(%{"id" => "a", "kind" => "frobnicate"})
    end

    test "rejects an invalid payload" do
      assert {:error, _} =
               Admin.decode_request(%{
                 "id" => "a",
                 "kind" => "deploy",
                 "payload" => %{"seed_type" => "bogus"}
               })
    end

    test "rejects a missing kind" do
      assert {:error, :missing_kind} = Admin.decode_request(%{"id" => "a"})
    end
  end

  describe "schemas" do
    test "StatusReport defaults active_deployments to an empty list" do
      assert {:ok, %StatusReport{version: "1.2.3", active_deployments: []}} =
               StatusReport.cast(%{"version" => "1.2.3"})
    end

    test "Reply casts a complete frame with an exit code" do
      assert {:ok, %Reply{kind: "complete", exit_code: 0}} =
               Reply.cast(%{"id" => "a", "kind" => "complete", "exit_code" => 0})
    end
  end

  test "admin schemas are registered in the spec but excluded from server-pushed titles" do
    spec = SowerClient.spec()

    for title <- ["AdminDeploy", "AdminReload", "AdminStatus", "AdminStatusReport", "AdminReply"] do
      assert Map.has_key?(spec.components.schemas, title), "#{title} missing from spec()"
      refute title in SowerClient.server_pushed_schema_titles()
    end
  end
end
