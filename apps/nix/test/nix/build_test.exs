defmodule Nix.BuildTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nix.Build

  # Use the project's own flake for real buildable packages
  @project_root Path.expand("../../../..", __DIR__)

  describe "run/2" do
    @tag timeout: 120_000
    test "successfully builds a derivation from flake" do
      {:ok, eval} = Nix.Eval.run(@project_root, attr: "packages.x86_64-linux.cli")

      {status, build} = Build.run(eval)

      assert status == :ok
      assert build.eval == eval
      assert build.store_path != nil
      assert String.starts_with?(build.store_path, "/nix/store/")
      assert build.status == :ok
      assert %DateTime{} = build.start_time
      assert %DateTime{} = build.end_time
    end

    test "returns error for invalid derivation path" do
      capture_log(fn ->
        {status, build} =
          Build.run(%Nix.Eval{output: %{"drvPath" => "/nix/store/nonexistent.drv"}})

        assert status == :error
        assert build.status == :error
        assert build.store_path == nil
        log = Enum.join(build.log, "\n")
        assert String.contains?(log, "error")
        assert String.contains?(log, "No such file or directory")
      end)
    end
  end
end
