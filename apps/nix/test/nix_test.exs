defmodule NixTest do
  use ExUnit.Case
  doctest Nix

  test "greets the world" do
    assert Nix.hello() == :world
  end
end
