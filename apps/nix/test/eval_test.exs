defmodule Nix.EvalTest do
  use ExUnit.Case

  test "detect_type/1" do
    assert Nix.Eval.Request.detect_type("/tmp#") == :flake
    assert Nix.Eval.Request.detect_type(Path.expand("../../..", __DIR__)) == :flake
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
