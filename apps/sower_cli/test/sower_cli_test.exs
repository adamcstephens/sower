defmodule SowerCliTest do
  use ExUnit.Case
  doctest SowerCli

  test "greets the world" do
    assert SowerCli.hello() == :world
  end
end
