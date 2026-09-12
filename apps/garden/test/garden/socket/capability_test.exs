defmodule Garden.Socket.CapabilityTest do
  use ExUnit.Case, async: false

  import Slipstream.Signatures, only: [command: 1]

  test "advertises direct override when joining its private channel" do
    storage = Garden.Storage.read()
    on_exit(fn -> Garden.Storage.write(storage) end)

    Garden.Storage.write(%Garden.Storage{garden_sid: "override-capable-garden"})
    socket = %{Slipstream.new_socket() | channel_pid: self()}

    assert {:ok, _socket} =
             Garden.Socket.handle_join("garden:lobby", %{"conn_sid" => "connection"}, socket)

    assert_received command(%Slipstream.Commands.JoinTopic{
                      topic: "garden:override-capable-garden",
                      payload: %{direct_override: true}
                    })
  end
end
