defmodule SowerClientTest do
  use ExUnit.Case
  doctest SowerClient

  test "greets the world" do
    assert SowerClient.hello() == :world
  end
end
