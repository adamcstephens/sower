defmodule VMManager.ExplicitLayoutTest do
  use ExUnit.Case, async: true
  alias CloudHypervisor.Config, as: Native
  alias VMManager.{Config, Machine, Storage}
  alias VMManager.Storage.EphemeralDisk

  @moduletag :tmp_dir

  test "generic kernel-only configuration omits devices and scratch allocation", %{tmp_dir: dir} do
    config = %Config{id: "generic", kernel: "/kernel"}
    assert :ok = Config.validate(config)
    assert {:ok, []} = Storage.prepare(config, dir)
    assert {:ok, []} = File.ls(dir)
    assert [vms: 1, cpus: 1, memory: 536_870_912, scratch_bytes: 0] = Storage.resources(config)
    native = Machine.build(config, dir, nil)
    assert native.initramfs == nil
    assert native.disks == []
    assert native.net == []
    assert native.serial == nil
    assert native.console == nil
    assert native.rng == nil
    assert native.vsock == nil
    assert native.cmdline == " sower.vm.id=generic"
  end

  test "preserves native disk order and formats only requested ephemeral files", %{tmp_dir: dir} do
    native = %Native.Disk{path: Path.join(dir, "caller.img"), readonly: false}
    File.write!(native.path, "caller data")

    config = %Config{
      id: "ordered",
      kernel: "/kernel",
      cpus: 2,
      disks: [
        %EphemeralDisk{name: "raw.img", bytes: 4096},
        native,
        %EphemeralDisk{name: "formatted.img", bytes: 8192, filesystem: :ext4, label: "data"}
      ]
    }

    assert :ok = Config.validate(config)

    assert {:ok, [["mkfs.ext4", "-q", "-F", "-L", "data", formatted]]} =
             Storage.prepare(config, dir)

    assert formatted == Path.join(dir, "formatted.img")
    assert File.stat!(formatted).size == 8192
    assert File.stat!(Path.join(dir, "raw.img")).size == 4096
    assert File.read!(native.path) == "caller data"
    assert Storage.resources(config)[:scratch_bytes] == 12_288
    assert [first, ^native, last] = Machine.build(config, dir, nil).disks
    assert first.path == Path.join(dir, "raw.img")
    assert last.path == formatted
    assert {:error, :eexist} = Storage.prepare(config, dir)
    assert File.read!(native.path) == "caller data"
  end

  test "rejects traversal, reserved names, duplicates and caller file collisions", %{tmp_dir: dir} do
    for name <- ["../outside", "sub/file", "..", ".", "", "serial.log", "sub\\file"] do
      config = %Config{
        id: "invalid",
        kernel: "/kernel",
        disks: [%EphemeralDisk{name: name, bytes: 1}]
      }

      assert {:error, :invalid_storage} = Config.validate(config)
    end

    disk = %EphemeralDisk{name: "same.img", bytes: 1}
    config = %Config{id: "invalid", kernel: "/kernel", disks: [disk, disk]}
    assert {:error, :invalid_storage} = Config.validate(config)

    config = %{config | disks: [disk, %Native.Disk{path: Path.join(dir, disk.name)}]}
    assert {:error, :invalid_storage} = Storage.prepare(config, dir)
    assert {:ok, []} = File.ls(dir)
  end

  test "cleanup checks the complete directory before deleting owned files", %{tmp_dir: dir} do
    runtime = Path.join(dir, "runtime")
    File.mkdir!(runtime)
    caller = Path.join(dir, "caller.img")
    File.write!(caller, "retained")

    config = %Config{
      id: "cleanup",
      kernel: "/kernel",
      disks: [%Native.Disk{path: caller}, %EphemeralDisk{name: "owned.img", bytes: 4096}],
      serial: %Native.Output{mode: :file, file: "serial.log"}
    }

    assert {:ok, []} = Storage.prepare(config, runtime)
    File.write!(Path.join(runtime, "serial.log"), "log")
    File.write!(Path.join(runtime, "unknown"), "custody")
    assert {:error, :unowned_storage} = Storage.cleanup(config, runtime)
    assert File.exists?(Path.join(runtime, "owned.img"))
    assert File.exists?(Path.join(runtime, "serial.log"))
    File.rm!(Path.join(runtime, "unknown"))
    assert :ok = Storage.cleanup(config, runtime)
    refute File.exists?(runtime)
    assert File.read!(caller) == "retained"
  end

  test "cleanup refuses symlinks without deleting any owned regular files", %{tmp_dir: dir} do
    runtime = Path.join(dir, "runtime")
    File.mkdir!(runtime)
    target = Path.join(dir, "target")
    File.write!(target, "retained")
    File.write!(Path.join(runtime, "first"), "owned")
    File.ln_s!(target, Path.join(runtime, "second"))

    config = %Config{
      id: "cleanup",
      kernel: "/kernel",
      disks: [
        %EphemeralDisk{name: "first", bytes: 1},
        %EphemeralDisk{name: "second", bytes: 1}
      ]
    }

    assert {:error, :unowned_storage} = Storage.cleanup(config, runtime)
    assert File.read!(Path.join(runtime, "first")) == "owned"
    assert File.read!(target) == "retained"
  end

  test "attachment admission requires caller-owned disks and resolved output paths" do
    config = %Config{
      id: "attached",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: "/api.sock"
    }

    assert :ok = Config.validate(config)

    assert {:error, :invalid_attachment_layout} =
             Config.validate(%{config | disks: [%EphemeralDisk{name: "scratch", bytes: 1}]})

    for device <- [:serial, :console] do
      invalid = Map.put(config, device, %Native.Output{mode: :file, file: "serial.log"})
      assert {:error, :invalid_attachment_layout} = Config.validate(invalid)
      valid = Map.put(config, device, %Native.Output{mode: :file, file: "/logs/serial.log"})
      assert :ok = Config.validate(valid)
    end
  end

  test "attachment matching compares ordered native declarations and ignores native default fields",
       %{tmp_dir: dir} do
    config = %Config{
      id: "attached",
      kernel: "/kernel",
      disks: [
        %Native.Disk{path: "/root", readonly: true},
        %Native.Disk{path: "/data", readonly: false}
      ]
    }

    actual = Machine.build(config, dir, nil) |> Native.to_api()
    actual = put_in(actual, ["disks", Access.at(0), "num_queues"], 1)

    info = %CloudHypervisor.API.Info{
      state: "Running",
      config: actual,
      memory_actual_size: config.memory
    }

    assert Machine.matches?(info, config, dir, nil)
    refute Machine.matches?(info, %{config | disks: Enum.reverse(config.disks)}, dir, nil)
    refute Machine.matches?(info, %{config | id: "different"}, dir, nil)
    refute Machine.matches?(info, %{config | kernel: "/other"}, dir, nil)
  end

  test "attachment matching rejects undeclared disks, network and vsock", %{tmp_dir: dir} do
    config = %Config{id: "generic", kernel: "/kernel"}
    actual = Machine.build(config, dir, nil) |> Native.to_api()

    info = %CloudHypervisor.API.Info{
      state: "Running",
      config: actual,
      memory_actual_size: config.memory
    }

    assert Machine.matches?(info, config, dir, nil)

    for {key, value} <- [
          {"disks", [%{"path" => "/unexpected"}]},
          {"net", [%{"tap" => "unexpected", "mac" => "02:00:00:00:00:01"}]},
          {"vsock", %{"cid" => 3, "socket" => "/unexpected"}}
        ] do
      refute Machine.matches?(%{info | config: Map.put(actual, key, value)}, config, dir, nil)
    end
  end

  test "rejects console and output aliases before allocating ephemeral storage", %{tmp_dir: dir} do
    disk = %EphemeralDisk{name: "scratch.img", bytes: 4096}
    base = %Config{id: "aliases", kernel: "/kernel", disks: [disk]}
    native = %Native.Disk{path: Path.join(dir, "caller.img")}
    File.write!(native.path, "caller data")

    for config <- [
          %{base | console: %Native.Output{mode: :file, file: "scratch.img"}},
          %{
            base
            | disks: [disk, native],
              console: %Native.Output{mode: :file, file: native.path}
          },
          %{
            base
            | serial: %Native.Output{mode: :file, file: "shared.log"},
              console: %Native.Output{mode: :file, file: Path.join(dir, "shared.log")}
          }
        ] do
      assert {:error, :invalid_storage} = Storage.prepare(config, dir)
      refute File.exists?(Path.join(dir, "scratch.img"))
      assert File.read!(native.path) == "caller data"
    end
  end

  test "cleans declared relative serial and console outputs", %{tmp_dir: dir} do
    runtime = Path.join(dir, "runtime")
    File.mkdir!(runtime)

    config = %Config{
      id: "outputs",
      kernel: "/kernel",
      serial: %Native.Output{mode: :file, file: "boot.log"},
      console: %Native.Output{mode: :file, file: "console.log"}
    }

    assert :ok = Config.validate(config)
    File.write!(Path.join(runtime, "boot.log"), "serial")
    File.write!(Path.join(runtime, "console.log"), "console")
    assert :ok = Storage.cleanup(config, runtime)
    refute File.exists?(runtime)
  end

  test "preserves absolute serial output even when located in the runtime", %{tmp_dir: dir} do
    runtime = Path.join(dir, "runtime")
    File.mkdir!(runtime)
    output = Path.join(runtime, "serial.log")
    File.write!(output, "caller log")

    config = %Config{
      id: "absolute-output",
      kernel: "/kernel",
      serial: %Native.Output{mode: :file, file: output}
    }

    assert {:error, :unowned_storage} = Storage.cleanup(config, runtime)
    assert File.read!(output) == "caller log"
  end

  test "rejects relative output traversal before allocating storage", %{tmp_dir: dir} do
    for device <- [:serial, :console], name <- ["../outside", "sub/output.log", ".", ""] do
      config =
        Map.put(
          %Config{
            id: "invalid-output",
            kernel: "/kernel",
            disks: [%EphemeralDisk{name: "scratch.img", bytes: 1}]
          },
          device,
          %Native.Output{mode: :file, file: name}
        )

      assert {:error, :invalid_output} = Config.validate(config)
      assert {:error, :invalid_storage} = Storage.prepare(config, dir)
      refute File.exists?(Path.join(dir, "scratch.img"))
    end
  end

  test "attachment matching rejects undeclared initramfs", %{tmp_dir: dir} do
    config = %Config{id: "no-initrd", kernel: "/kernel"}
    actual = Machine.build(config, dir, nil) |> Native.to_api()

    info = %CloudHypervisor.API.Info{
      state: "Running",
      config: put_in(actual, ["payload", "initramfs"], "/unexpected-initrd"),
      memory_actual_size: config.memory
    }

    refute Machine.matches?(info, config, dir, nil)
  end

  test "launch admission requires process-owned vsock socket allocation" do
    config = %Config{
      id: "launch-socket",
      kernel: "/kernel",
      vsock: %Native.Vsock{cid: 3, socket: nil}
    }

    assert :ok = Config.validate(config)

    assert {:error, :invalid_vsock} =
             Config.validate(%{config | vsock: %{config.vsock | socket: "/caller.sock"}})
  end

  test "attachment admission requires explicit native vsock socket identity" do
    config = %Config{
      id: "attach-socket",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: "/api.sock",
      vsock: %Native.Vsock{cid: 3, socket: "/guest.sock"}
    }

    assert :ok = Config.validate(config)

    for socket <- [nil, 42] do
      assert {:error, :invalid_attachment_layout} =
               Config.validate(%{config | vsock: %{config.vsock | socket: socket}})
    end
  end

  test "Sower attachment admission requires the verified native socket and control endpoint" do
    config = %Config{
      id: "sower-attach",
      kernel: "/kernel",
      mode: :attach,
      guest: %Config.SowerGuest{},
      control_endpoint: "/api.sock",
      vsock: %Native.Vsock{cid: 3, socket: "/guest.sock"}
    }

    assert :ok = Config.validate(config)

    for endpoint <- [nil, 42] do
      assert {:error, :invalid_attachment_layout} =
               Config.validate(%{config | control_endpoint: endpoint})
    end

    agentless = %{config | guest: :none, vsock: nil}
    assert :ok = Config.validate(agentless)

    for endpoint <- [nil, 42] do
      assert {:error, :invalid_attachment_layout} =
               Config.validate(%{agentless | control_endpoint: endpoint})
    end
  end
end
