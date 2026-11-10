defmodule VMManager.RuntimeResourcesTest do
  use ExUnit.Case, async: true

  for {existing, expected_mode} <- [{false, 0o700}, {true, 0o755}] do
    test "prepares runtime resources without changing existing base permissions: #{existing}" do
      directory =
        Path.join(System.tmp_dir!(), "vm-resources-#{System.unique_integer([:positive])}")

      File.mkdir!(directory)
      base = Path.join([directory, "missing", "runtimes"])

      prepare_base_fixture(base, unquote(existing))

      formatter = Path.join(directory, "formatter")
      marker = Path.join(directory, "formatting")
      File.write!(formatter, "#!/usr/bin/env sh\nprintf ready > '#{marker}'\nexec sleep 60\n")
      File.chmod!(formatter, 0o700)
      on_exit(fn -> File.rm_rf!(directory) end)

      config = %VMManager.Config{
        id: "missing-base",
        kernel: "/kernel",
        initrd: "/initrd",
        disks: [
          %VMManager.Storage.EphemeralDisk{name: "scratch.ext4", bytes: 1024, filesystem: :ext4}
        ],
        runtime_directory: base,
        mkfs: formatter
      }

      attempt_directory = VMManager.Guard.runtime_directory(base, "persisted-attempt")
      options = Keyword.put(VMManager.Config.to_options(config), :attempt, "persisted-attempt")
      {:ok, execution} = VMManager.Execution.start_link(options)
      on_exit(fn -> if Process.alive?(execution), do: GenServer.stop(execution) end)
      await_file(marker, System.monotonic_time(:millisecond) + 2_000)
      assert File.read!(marker) == "ready"
      assert {:ok, %{mode: mode}} = File.stat(base)
      assert Bitwise.band(mode, 0o777) == unquote(expected_mode)
      assert %VMManager.Status{directory: runtime} = GenServer.call(execution, :status)
      assert Path.dirname(runtime) == base
      assert runtime == attempt_directory
      assert {:ok, %{mode: child_mode}} = File.stat(runtime)
      assert Bitwise.band(child_mode, 0o777) == 0o700
      assert File.exists?(Path.join(runtime, "scratch.ext4"))
      assert :ok = GenServer.call(execution, {:stop, %VMManager.Stop{mode: :force}}, 5_000)
      refute File.exists?(runtime)
      assert File.dir?(base)
      assert File.exists?(marker)
    end
  end

  test "reboot cleanup removes only known attempt files and retains unknown contents" do
    base = Path.join(System.tmp_dir!(), "vm-reboot-#{System.unique_integer([:positive])}")
    attempt = VMManager.Guard.runtime_directory(base, "persisted-attempt")
    File.mkdir_p!(attempt)
    on_exit(fn -> File.rm_rf!(base) end)
    persistent = Path.join(base, "persistent.ext4")
    File.write!(persistent, "persistent data")
    scratch = Path.join(attempt, "scratch.ext4")
    serial = Path.join(attempt, "serial.log")
    unknown = Path.join(attempt, "unexpected")
    File.write!(scratch, "ephemeral")
    File.write!(serial, "serial")
    File.write!(unknown, "retain")

    config = %VMManager.Config{
      id: "reboot",
      kernel: "/kernel",
      disks: [
        %VMManager.Storage.EphemeralDisk{name: "scratch.ext4", bytes: 1024, filesystem: :ext4}
      ],
      serial: %CloudHypervisor.Config.Output{mode: :file, file: "serial.log"}
    }

    assert {:error, :unowned_storage} =
             VMManager.Storage.cleanup(config, attempt)

    assert File.read!(scratch) == "ephemeral"
    assert File.read!(serial) == "serial"
    assert File.read!(unknown) == "retain"
    File.rm!(unknown)
    assert :ok = VMManager.Storage.cleanup(config, attempt)
    refute File.exists?(attempt)
    assert File.read!(persistent) == "persistent data"
    assert File.dir?(base)
    assert :ok = VMManager.Storage.cleanup(config, attempt)
    assert :ok = VMManager.Storage.cleanup(config, nil)
  end

  defp prepare_base_fixture(_base, false), do: :ok

  defp prepare_base_fixture(base, true) do
    File.mkdir_p!(base)
    File.chmod!(base, 0o755)
  end

  defp await_file(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      await_file(path, deadline)
    end
  end
end
