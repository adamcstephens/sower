defmodule Nix.Build.JobsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nix.Build.Jobs

  @project_root Path.expand("../../../../..", __DIR__)

  describe "run/2" do
    @tag timeout: 120_000
    test "successfully builds multiple derivations concurrently" do
      {:ok, eval} = Nix.Eval.run(@project_root, attr: "packages.x86_64-linux.cli")

      {status, result} = Jobs.run([eval, eval], max_workers: 2)

      assert status == :ok
      assert %Jobs.Result{} = result
      assert result.status == :ok
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
      assert DateTime.compare(result.end_time, result.start_time) in [:gt, :eq]

      assert length(result.results) == 2

      for build <- result.results do
        assert build.status == :ok
        assert build.store_path != nil
        assert String.starts_with?(build.store_path, "/nix/store/")
      end
    end

    test "returns error status when any build fails" do
      capture_log(fn ->
        valid_eval = %Nix.Eval{output: %{"drvPath" => "/nix/store/nonexistent-valid.drv"}}
        invalid_eval = %Nix.Eval{output: %{"drvPath" => "/nix/store/nonexistent.drv"}}

        {status, result} = Jobs.run([valid_eval, invalid_eval], max_workers: 2)

        assert status == :error
        assert result.status == :error
        assert length(result.results) == 2
        assert Enum.all?(result.results, &(&1.status == :error))
      end)
    end

    test "handles empty list" do
      {status, result} = Jobs.run([])

      assert status == :ok
      assert result.status == :ok
      assert result.results == []
    end

    test "respects max_workers option" do
      capture_log(fn ->
        evals =
          for i <- 1..4 do
            %Nix.Eval{output: %{"drvPath" => "/nix/store/test-#{i}.drv"}}
          end

        {status, result} = Jobs.run(evals, max_workers: 1)

        assert length(result.results) == 4
        assert status == :error
        assert result.status == :error
      end)
    end
  end
end
