defmodule PeerNodeTest do
  use ExUnit.Case
  doctest PeerNode

  test "greets the world" do
    assert PeerNode.hello() == :world
  end
end
