defmodule Nix.Eval.JobsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Nix.Eval.Jobs

  @fixtures_path Path.join([__DIR__, "..", "..", "fixtures"])

  describe "run/2 (blocking)" do
    test "returns {:ok, summary, results} on success" do
      path = Path.join(@fixtures_path, "derivation.nix")

      {status, report} = Jobs.run(path)

      assert status == :ok
      assert is_list(report.results)
      assert length(report.results) > 0
    end

    test "returns {:error, summary, results} when there are errors" do
      path = Path.join(@fixtures_path, "error.nix")

      capture_log(fn ->
        {status, _report} = Jobs.run(path)

        assert status == :error
      end)
    end

    test "maintains backwards compatibility with fixture evaluations" do
      path = Path.join(@fixtures_path, "nested.nix")

      {status, report} = Jobs.run(path)

      assert status == :ok
      assert is_list(report.results)

      # All results should be successful evals
      assert Enum.all?(report.results, &match?(%Nix.Eval{status: :ok}, &1))
    end
  end
end
