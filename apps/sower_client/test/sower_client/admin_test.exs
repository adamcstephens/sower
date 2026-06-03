defmodule SowerClient.AdminTest do
  use ExUnit.Case, async: true

  alias SowerClient.Admin

  describe "Request.cast/1" do
    test "casts a deploy request and defaults v and force" do
      assert {:ok, request} = Admin.Request.cast(%{"id" => "abc", "kind" => "deploy"})
      assert request.id == "abc"
      assert request.kind == "deploy"
      assert request.v == 1
      assert request.force == false
      assert request.seed_type == nil
      assert request.sid == nil
    end

    test "keeps deploy scoping fields" do
      assert {:ok, request} =
               Admin.Request.cast(%{
                 "id" => "abc",
                 "kind" => "deploy",
                 "seed_type" => "nixos",
                 "force" => true
               })

      assert request.seed_type == "nixos"
      assert request.force == true
    end

    test "rejects an unknown kind" do
      assert {:error, _} = Admin.Request.cast(%{"id" => "abc", "kind" => "frobnicate"})
    end

    test "rejects an unknown seed_type" do
      assert {:error, _} =
               Admin.Request.cast(%{"id" => "abc", "kind" => "deploy", "seed_type" => "bogus"})
    end
  end

  describe "Status.cast/1" do
    test "defaults active_deployments to an empty list" do
      assert {:ok, status} = Admin.Status.cast(%{"version" => "1.2.3"})
      assert status.version == "1.2.3"
      assert status.active_deployments == []
    end
  end

  describe "Reply.cast/1" do
    test "casts a complete frame with an exit code" do
      assert {:ok, reply} =
               Admin.Reply.cast(%{"id" => "abc", "kind" => "complete", "exit_code" => 0})

      assert reply.kind == "complete"
      assert reply.exit_code == 0
    end
  end

  test "admin schemas are registered in the spec but excluded from server-pushed titles" do
    spec = SowerClient.spec()

    for title <- ["AdminRequest", "AdminReply", "AdminStatus"] do
      assert Map.has_key?(spec.components.schemas, title), "#{title} missing from spec()"
      refute title in SowerClient.server_pushed_schema_titles()
    end
  end
end
