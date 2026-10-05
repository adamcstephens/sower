defmodule Nix.ProcessOutcomesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  setup do
    directory = Path.join(System.tmp_dir!(), "nix-process-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    path = System.get_env("PATH")
    System.put_env("PATH", directory <> ":" <> (path || ""))

    on_exit(fn ->
      if path, do: System.put_env("PATH", path), else: System.delete_env("PATH")
      File.rm_rf!(directory)
    end)

    {:ok, directory: directory}
  end

  test "build startup failure returns an error result", %{directory: directory} do
    executable(directory, "nix-build", <<0>>)
    eval = %Nix.Eval{output: %{"drvPath" => "/nix/store/test.drv"}}

    capture_log(fn ->
      assert {:error, build} = Nix.Build.run(eval, timeout: 2_000)
      assert build.eval == eval
      assert build.status == :error
      assert Enum.join(build.log, "\n") =~ "startup"
    end)
  end

  test "eval startup failure returns an error result", %{directory: directory} do
    executable(directory, "nix-instantiate", <<0>>)

    capture_log(fn ->
      assert {:error, eval} = Nix.Eval.run("/tmp/expression.nix", timeout: 2_000)
      assert eval.request.path == "/tmp/expression.nix"
      assert eval.status == :error
      assert Enum.join(eval.errors, "\n") =~ "startup"
    end)
  end

  test "store startup failure returns the startup reason", %{directory: directory} do
    executable(directory, "nix-store", <<0>>)
    assert {:error, {:startup, message}} = Nix.Store.realize("/nix/store/test")
    assert is_binary(message)
  end

  test "attic startup failure is returned without formatting a tuple as a string", %{
    directory: directory
  } do
    executable(directory, "attic", <<0>>)

    capture_log(fn ->
      assert {:error, %Nix.Cache.UploadError{output: output}} =
               Nix.Cache.Attic.upload(["/nix/store/test"], %{cache: "server:cache"})

      assert output =~ "startup"
    end)
  end

  test "store returns an actual terminating signal rather than hanging", %{directory: directory} do
    executable(directory, "nix-store", "#!/usr/bin/env sh\nprintf output\nkill -TERM $$\n")
    task = Task.async(fn -> Nix.Store.realize("/nix/store/test") end)
    assert {:error, {:signal, 15}} = Task.await(task, 2_000)
  end

  test "attic returns signal failure and preserves output and stdin", %{directory: directory} do
    executable(
      directory,
      "attic",
      "#!/usr/bin/env sh\ncat\nprintf diagnostic >&2\nkill -TERM $$\n"
    )

    capture_log(fn ->
      task =
        Task.async(fn ->
          Nix.Cache.Attic.upload(["/nix/store/test"], %{cache: "server:cache"})
        end)

      assert {:error, %Nix.Cache.UploadError{exit_code: 143, output: output}} =
               Task.await(task, 2_000)

      assert output =~ "diagnostic"
      assert output =~ "/nix/store/test"
    end)
  end

  test "eval returns signal failure with its complete output", %{directory: directory} do
    executable(
      directory,
      "nix-instantiate",
      "#!/usr/bin/env sh\nprintf '{\"answer\":42}'\nprintf diagnostic >&2\nkill -TERM $$\n"
    )

    capture_log(fn ->
      assert {:error, eval} = Nix.Eval.run("/tmp/expression.nix", timeout: 2_000)
      assert eval.output == %{"answer" => 42}
      assert "diagnostic" in eval.errors
    end)
  end

  test "store completion preserves the final output bytes", %{directory: directory} do
    executable(directory, "nix-store", "#!/usr/bin/env sh\nprintf first\nprintf final\n")
    assert {:ok, output} = Nix.Store.realize("/nix/store/test")
    assert IO.iodata_to_binary(output) == "firstfinal"
  end

  test "store returns cleanup failure when its native runner dies", %{directory: directory} do
    executable(directory, "nix-store", "#!/usr/bin/env sh\nsleep 0.05\nkill -KILL \"$PPID\"\n")
    task = Task.async(fn -> Nix.Store.realize("/nix/store/test") end)
    assert {:error, {:cleanup_failed, message}} = Task.await(task, 2_000)
    assert message =~ "cleanup"
  end

  test "attic reports incomplete cleanup instead of waiting for upload timeout", %{
    directory: directory
  } do
    executable(directory, "attic", "#!/usr/bin/env sh\ncat\nkill -KILL \"$PPID\"\n")

    capture_log(fn ->
      task =
        Task.async(fn ->
          Nix.Cache.Attic.upload(["/nix/store/test"], %{cache: "server:cache"})
        end)

      assert {:error, %Nix.Cache.UploadError{output: output}} = Task.await(task, 2_000)
      assert output =~ "cleanup"
    end)
  end

  test "build returns signal failure with its complete stderr", %{directory: directory} do
    executable(
      directory,
      "nix-build",
      "#!/usr/bin/env sh\nprintf diagnostic >&2\nkill -TERM $$\n"
    )

    capture_log(fn ->
      eval = %Nix.Eval{output: %{"drvPath" => "/nix/store/test.drv"}}
      assert {:error, build} = Nix.Build.run(eval, timeout: 2_000)
      assert "diagnostic" in build.log
    end)
  end

  test "build returns cleanup failure rather than waiting for the caller timeout", %{
    directory: directory
  } do
    executable(directory, "nix-build", "#!/usr/bin/env sh\nsleep 0.05\nkill -KILL \"$PPID\"\n")

    capture_log(fn ->
      eval = %Nix.Eval{output: %{"drvPath" => "/nix/store/test.drv"}}
      assert {:error, build} = Nix.Build.run(eval, timeout: 2_000)
      assert Enum.join(build.log, "\n") =~ "cleanup"
    end)
  end

  test "eval returns cleanup failure rather than waiting for the caller timeout", %{
    directory: directory
  } do
    executable(
      directory,
      "nix-instantiate",
      "#!/usr/bin/env sh\nsleep 0.05\nkill -KILL \"$PPID\"\n"
    )

    capture_log(fn ->
      assert {:error, eval} = Nix.Eval.run("/tmp/expression.nix", timeout: 2_000)
      assert Enum.join(eval.errors, "\n") =~ "cleanup"
    end)
  end

  defp executable(directory, name, contents) do
    filename = Path.join(directory, name)
    File.write!(filename, contents)
    File.chmod!(filename, 0o755)
  end
end
