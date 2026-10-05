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

  describe "quoted path selectors" do
    test "explicit selectors evaluate and build their intended jobs" do
      path = Path.join(@fixtures_path, "quoted.nix")

      for {selector, expected} <- [
            {~S("seed/host"), "plain\n"},
            {~S("seed/host.example"), "dotted\n"},
            {~S(nested."group.with.dot"."seed/host.example"), "nested\n"},
            {~S("seed/quote\"back\\\${literal}.example"), "escaped\n"}
          ] do
        request = Nix.Eval.Request.parse(path, attr: selector)
        assert {:ok, evaluations} = Jobs.run(request)
        assert {:ok, builds} = Nix.Build.Jobs.run(evaluations.results)
        assert [build] = builds.results
        assert File.read!(Path.join(build.store_path, "selected")) == expected
      end
    end

    test "automatic discovery preserves raw names and quoted parent boundaries" do
      path = Path.join(@fixtures_path, "quoted.nix")
      assert {:ok, evaluations} = Jobs.run(path)
      assert {:ok, builds} = Nix.Build.Jobs.run(evaluations.results)

      assert Enum.sort(
               Enum.map(builds.results, &File.read!(Path.join(&1.store_path, "selected")))
             ) == ["dotted\n", "escaped\n", "nested\n", "plain\n"]

      request = Nix.Eval.Request.parse(path, attr: ~S(nested."group.with.dot"))
      assert {:ok, evaluations} = Jobs.run(request)
      assert {:ok, builds} = Nix.Build.Jobs.run(evaluations.results)
      assert [build] = builds.results
      assert File.read!(Path.join(build.store_path, "selected")) == "nested\n"
    end
  end

  describe "timeout handling" do
    test "returns error result when GenServer times out" do
      path = Path.join(@fixtures_path, "nested.nix")

      capture_log(fn ->
        {status, result} = Jobs.run(path, timeout: 1)

        assert status == :error
        assert %Jobs.Result{} = result
        assert result.results == []
      end)
    end
  end
end
