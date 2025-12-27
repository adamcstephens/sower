defmodule Nix.Eval.RequestTest do
  use ExUnit.Case

  test "Nix.Eval.Type.detect/1" do
    assert Nix.Eval.Type.detect("/tmp#") == :flake
    assert Nix.Eval.Type.detect(Path.expand("../../../../..", __DIR__)) == :flake
  end

  test "parse_path/3" do
    assert Nix.Eval.Request.parse_path(:flake, "/tmp", nil) == {"/tmp", nil}
    assert Nix.Eval.Request.parse_path(:flake, "/tmp#", nil) == {"/tmp", nil}
    assert Nix.Eval.Request.parse_path(:flake, "/tmp#package", nil) == {"/tmp", "package"}
    assert Nix.Eval.Request.parse_path(:flake, "/tmp", "attr") == {"/tmp", "attr"}

    assert Nix.Eval.Request.parse_path(:path, "/tmp", nil) == {"/tmp", nil}
    assert Nix.Eval.Request.parse_path(:path, "/tmp", "attr") == {"/tmp", "attr"}
  end
end
