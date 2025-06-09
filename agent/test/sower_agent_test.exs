defmodule SowerAgentTest do
  use ExUnit.Case
  doctest SowerAgent

  test "greets the world" do
    assert SowerAgent.hello() == :world
  end
end
