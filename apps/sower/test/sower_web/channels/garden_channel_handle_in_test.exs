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
end
