defmodule Nix.EvalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @fixtures_path Path.expand("../fixtures", __DIR__)

  describe "flake evaluation" do
    @tag :flake
    test "returns branch (attrset) for flake with nested attrs" do
      # Use the project's own flake
      project_root = Path.expand("../../../..", __DIR__)

      {:ok, state} = Nix.Eval.run(project_root, attr: "packages")

      assert state.status == :ok

      assert is_list(state.output),
             "Expected branch (list of requests), got: #{inspect(state.output)}"

      assert length(state.output) > 0

      # Each output should be a Request struct with the attr path extended
      first = hd(state.output)
      assert %Nix.Eval.Request{} = first
      assert first.type == :flake
      assert String.starts_with?(first.attr, "packages.")
    end

    @tag :flake
    test "returns leaf (derivation) for flake package" do
      project_root = Path.expand("../../../..", __DIR__)

      {:ok, state} = Nix.Eval.run(project_root, attr: "packages.x86_64-linux.cli")

      assert state.status == :ok
      assert is_map(state.output), "Expected leaf (derivation map), got: #{inspect(state.output)}"
      assert Map.has_key?(state.output, "drvPath")
      assert Map.has_key?(state.output, "storePath")
    end
  end

  describe "path evaluation" do
    @tag :path
    test "returns branch (attrset) for .nix file with attrs" do
      fixture_path = Path.join(@fixtures_path, "attrset.nix")

      {:ok, state} = Nix.Eval.run(fixture_path)

      assert state.status == :ok

      assert is_list(state.output),
             "Expected branch (list of requests), got: #{inspect(state.output)}"

      # Should have foo, bar, baz
      attr_names = Enum.map(state.output, & &1.attr)
      assert "foo" in attr_names
      assert "bar" in attr_names
      assert "baz" in attr_names
    end

    @tag :path
    test "returns leaf (derivation) for .nix file with derivation" do
      fixture_path = Path.join(@fixtures_path, "derivation.nix")

      {:ok, state} = Nix.Eval.run(fixture_path)

      assert state.status == :ok
      assert is_map(state.output), "Expected leaf (derivation map), got: #{inspect(state.output)}"
      assert Map.has_key?(state.output, "drvPath")
      assert Map.has_key?(state.output, "storePath")
    end

    @tag :path
    test "returns branch for nested structure" do
      fixture_path = Path.join(@fixtures_path, "nested.nix")

      {:ok, state} = Nix.Eval.run(fixture_path)

      assert state.status == :ok
      assert is_list(state.output)

      attr_names = Enum.map(state.output, & &1.attr)
      assert "packages" in attr_names
      assert "lib" in attr_names
    end

    @tag :path
    test "returns leaf when drilling into nested derivation" do
      fixture_path = Path.join(@fixtures_path, "nested.nix")

      {:ok, state} = Nix.Eval.run(fixture_path, attr: "packages.hello")

      assert state.status == :ok
      assert is_map(state.output), "Expected leaf (derivation map), got: #{inspect(state.output)}"
      assert Map.has_key?(state.output, "drvPath")
    end
  end

  describe "memory tracking" do
    test "reports memory peak" do
      fixture_path = Path.join(@fixtures_path, "attrset.nix")

      {:ok, state} = Nix.Eval.run(fixture_path)

      assert state.status == :ok
      assert is_list(state.mem_samples)
    end
  end

  describe "error handling" do
    test "returns error for invalid nix expression" do
      # Create a temp file with invalid nix
      tmp_path = Path.join(System.tmp_dir!(), "invalid_#{:rand.uniform(100_000)}.nix")
      File.write!(tmp_path, "{ foo = ")

      try do
        {{status, state}, log} = with_log(fn -> Nix.Eval.run(tmp_path) end)

        assert status == :error
        assert state.status == :error
        assert length(state.errors) > 0
        assert log =~ "warning"
        assert log =~ "Evaluation complete"
      after
        File.rm(tmp_path)
      end
    end

    test "returns error result when GenServer times out" do
      fixture_path = Path.join(@fixtures_path, "attrset.nix")

      capture_log(fn ->
        {status, eval} = Nix.Eval.run(fixture_path, timeout: 1)

        assert status == :error
        assert eval.status == :error
        assert is_list(eval.errors)
        assert Enum.any?(eval.errors, &String.contains?(&1, "timeout"))
      end)
    end
  end

  describe "timing" do
    test "records start and end times" do
      fixture_path = Path.join(@fixtures_path, "attrset.nix")
      before = DateTime.utc_now()

      {:ok, state} = Nix.Eval.run(fixture_path)

      after_time = DateTime.utc_now()

      assert DateTime.compare(state.start_time, before) in [:gt, :eq]
      assert DateTime.compare(state.end_time, after_time) in [:lt, :eq]
      assert DateTime.compare(state.end_time, state.start_time) in [:gt, :eq]
    end
  end
end
