defmodule IncusClientTest do
  use ExUnit.Case
  doctest IncusClient

  test "greets the world" do
    assert IncusClient.hello() == :world
  end
end
