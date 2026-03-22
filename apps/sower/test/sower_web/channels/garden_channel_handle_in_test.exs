defmodule SowerWeb.GardenChannelHandleInTest do
  use SowerWeb.ChannelCase, async: true

  describe "ping" do
    test "replies with pong" do
      %{socket: socket} = connect_and_join_garden()

      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, :pong
    end
  end

  describe "garden:hello" do
    test "returns garden info for an existing garden" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      ref =
        push(socket, "garden:hello", %{
          "garden_sid" => garden.sid,
          "local_sid" => garden.local_sid,
          "name" => garden.name
        })

      assert_reply ref, :ok, reply
      assert reply.sid == garden.sid
    end

    test "registers a new garden when garden_sid is nil" do
      %{socket: socket} = connect_and_join_garden()

      local_sid = SowerClient.Sid.generate("local")

      ref =
        push(socket, "garden:hello", %{
          "local_sid" => local_sid,
          "name" => "new-garden"
        })

      assert_reply ref, :ok, reply
      assert is_binary(reply.sid)
    end

    test "accepts legacy agent:hello event" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      ref =
        push(socket, "agent:hello", %{
          "garden_sid" => garden.sid,
          "local_sid" => garden.local_sid,
          "name" => garden.name
        })

      assert_reply ref, :ok, reply
      assert reply.sid == garden.sid
    end

    test "normalizes legacy agent_sid field to garden_sid" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      ref =
        push(socket, "garden:hello", %{
          "agent_sid" => garden.sid,
          "local_sid" => garden.local_sid,
          "name" => garden.name
        })

      assert_reply ref, :ok, reply
      assert reply.sid == garden.sid
    end
  end

  describe "deployment:request" do
    test "returns request_id for valid deployment request" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "deploy-req-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      ref =
        push(socket, "deployment:request", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "subscription_sids" => [subscription.sid]
        })

      assert_reply ref, :ok, %{request_id: request_id}
      assert is_binary(request_id)
    end

    test "returns error for unknown subscription" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:request", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "subscription_sids" => ["nonexistent_sid"]
        })

      assert_reply ref, :error, :subscription_not_found
    end
  end

  describe "deployment:status" do
    test "updates deployment state to acknowledged" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "deploy-status-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:status", %{
          "deployment_sid" => deployment.sid,
          "status" => "acknowledged"
        })

      assert_reply ref, :ok, reply
      assert reply.state == :acknowledged
    end

    test "returns error for unknown deployment" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:status", %{
          "deployment_sid" => "nonexistent_sid",
          "status" => "acknowledged"
        })

      assert_reply ref, :error, :deployment_not_found
    end
  end

  describe "deployment:result" do
    test "records deployment result and marks completed" do
      %{socket: socket, garden: garden} = connect_and_join_garden()

      seed = seed_fixture(%{name: "deploy-result-seed", seed_type: "nixos"})

      subscription =
        subscription_fixture(%{
          garden_id: garden.id,
          seed_name: seed.name,
          seed_type: seed.seed_type
        })

      deployment =
        deployment_fixture(%{
          garden_id: garden.id,
          seeds: [seed],
          subscriptions: [subscription]
        })

      ref =
        push(socket, "deployment:result", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "deployment_sid" => deployment.sid,
          "result" => "success",
          "deployed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        })

      assert_reply ref, :ok, reply
      assert reply.state == :completed
      assert reply.result == :success
    end

    test "returns error for unknown deployment" do
      %{socket: socket} = connect_and_join_garden()

      ref =
        push(socket, "deployment:result", %{
          "request_id" => SowerClient.Sid.generate("req"),
          "deployment_sid" => "nonexistent_sid",
          "result" => "success"
        })

      assert_reply ref, :error, :deployment_not_found
    end
  end
end
