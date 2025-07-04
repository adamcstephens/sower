defmodule SowerDevTest do
  use ExUnit.Case
  doctest SowerDev

  test "greets the world" do
    assert SowerDev.hello() == :world
  end
end
