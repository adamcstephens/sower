defmodule RexecTest do
  use ExUnit.Case, async: true

  describe "run_link/2" do
    test "runs a command and returns pid and ospid" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["echo", "hello"])

      assert is_pid(pid)
      assert is_integer(ospid)
      assert ospid > 0

      assert_receive {:stdout, ^ospid, "hello\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "captures stderr output" do
      Process.flag(:trap_exit, true)
      cmd = ["sh", "-c", "echo err >&2"]
      {:ok, pid, ospid} = Rexec.run_link(cmd)

      assert_receive {:stderr, ^ospid, "err\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "reports non-zero exit status" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sh", "-c", "exit 42"])

      assert_receive {:EXIT, ^pid, {:exit_status, 42}}, 5000
      assert is_integer(ospid)
    end

    test "handles multi-line stdout" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sh", "-c", "echo line1; echo line2"])

      stdout = collect_stdout(ospid, pid)
      assert stdout =~ "line1"
      assert stdout =~ "line2"
    end

    test "handles both stdout and stderr" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sh", "-c", "echo out; echo err >&2"])

      {stdout, stderr} = collect_output(ospid, pid)
      assert stdout =~ "out"
      assert stderr =~ "err"
    end

    test "passes environment variables to child" do
      Process.flag(:trap_exit, true)

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo $REXEC_TEST_VAR"],
          env: [{"REXEC_TEST_VAR", "hello_from_env"}]
        )

      assert_receive {:stdout, ^ospid, "hello_from_env\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "runs command in specified working directory" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["pwd"], cd: "/tmp")

      assert_receive {:stdout, ^ospid, "/tmp\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "removes environment variable when value is false" do
      Process.flag(:trap_exit, true)

      {:ok, pid, ospid} =
        Rexec.run_link(["sh", "-c", "echo ${HOME:-unset}"], env: [{"HOME", false}])

      assert_receive {:stdout, ^ospid, "unset\n"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end
  end

  describe "run/2" do
    test "runs a command with monitoring" do
      {:ok, pid, ospid} = Rexec.run(["echo", "hello"])

      assert is_pid(pid)
      assert is_integer(ospid)

      assert_receive {:stdout, ^ospid, "hello\n"}, 5000
      assert_receive {:DOWN, _ref, :process, ^pid, :normal}, 5000
    end

    test "reports non-zero exit via DOWN message" do
      {:ok, pid, ospid} = Rexec.run(["sh", "-c", "exit 7"])

      assert is_integer(ospid)
      assert_receive {:DOWN, _ref, :process, ^pid, {:exit_status, 7}}, 5000
    end
  end

  describe "send/2" do
    test "sends data to stdin" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["cat"])

      :ok = Rexec.send(ospid, "hello world")
      :ok = Rexec.send(ospid, :eof)

      assert_receive {:stdout, ^ospid, "hello world"}, 5000
      assert_receive {:EXIT, ^pid, :normal}, 5000
    end

    test "returns error for unknown ospid" do
      assert {:error, :not_found} = Rexec.send(999_999_999, "data")
      assert {:error, :not_found} = Rexec.send(999_999_999, :eof)
    end
  end

  describe "kill/2" do
    test "sends signal to terminate process" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sleep", "60"])

      assert is_integer(ospid)

      Rexec.kill(pid, :sigterm)
      assert_receive {:EXIT, ^pid, _reason}, 5000
    end

    test "accepts integer signals" do
      Process.flag(:trap_exit, true)
      {:ok, pid, ospid} = Rexec.run_link(["sleep", "60"])

      assert is_integer(ospid)

      # SIGTERM = 15
      Rexec.kill(pid, 15)
      assert_receive {:EXIT, ^pid, _reason}, 5000
    end
  end

  # Helpers

  defp collect_stdout(ospid, pid) do
    collect_stdout(ospid, pid, [])
  end

  defp collect_stdout(ospid, pid, acc) do
    receive do
      {:stdout, ^ospid, data} ->
        collect_stdout(ospid, pid, [data | acc])

      {:EXIT, ^pid, _} ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    after
      5000 ->
        acc |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp collect_output(ospid, pid) do
    collect_output(ospid, pid, [], [])
  end

  defp collect_output(ospid, pid, stdout, stderr) do
    receive do
      {:stdout, ^ospid, data} ->
        collect_output(ospid, pid, [data | stdout], stderr)

      {:stderr, ^ospid, data} ->
        collect_output(ospid, pid, stdout, [data | stderr])

      {:EXIT, ^pid, _} ->
        {
          stdout |> Enum.reverse() |> IO.iodata_to_binary(),
          stderr |> Enum.reverse() |> IO.iodata_to_binary()
        }
    after
      5000 ->
        {
          stdout |> Enum.reverse() |> IO.iodata_to_binary(),
          stderr |> Enum.reverse() |> IO.iodata_to_binary()
        }
    end
  end
end
