defmodule Garden.Socket.StatusTest do
  use ExUnit.Case, async: true

  test "does not request pending deployments from a server without the capability" do
    socket = Slipstream.new_socket()

    assert {:reply, nil, ^socket} =
             Garden.Socket.handle_call(:pending_deployments, {self(), make_ref()}, socket)
  end

  test "reports pending deployments as unknown while disconnected" do
    socket =
      Slipstream.new_socket() |> Slipstream.Socket.assign(:pending_deployments_supported, true)

    assert {:reply, nil, ^socket} =
             Garden.Socket.handle_call(:pending_deployments, {self(), make_ref()}, socket)
  end
end
