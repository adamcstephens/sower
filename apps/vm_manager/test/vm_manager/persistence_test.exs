defmodule VMManager.PersistenceTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Store}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "vm-manager-persistence-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      config: %Config{
        id: "durable-vm",
        kernel: "/kernel",
        initrd: "/initrd",
        disks: [%CloudHypervisor.Config.Disk{path: "/root", readonly: true, image_type: :raw}]
      }
    }
  end

  test "a fresh BEAM safely restores native disk, network lease and result models", %{
    directory: directory,
    config: config
  } do
    lease = %VMManager.Network{
      ownership: :external,
      devices: [%CloudHypervisor.Config.Net{tap: "tap0", mac: "02:00:00:00:00:01"}]
    }

    config = %{
      config
      | disks: [
          %CloudHypervisor.Config.Disk{path: "/persistent", readonly: false, image_type: :raw},
          %VMManager.Storage.EphemeralDisk{name: "scratch.ext4", bytes: 1024, filesystem: :ext4}
        ],
        persistent_disks: ["/persistent"],
        guest: %Config.SowerGuest{},
        vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: nil},
        serial: %CloudHypervisor.Config.Output{mode: :file, file: "serial.log"},
        console: %CloudHypervisor.Config.Output{mode: :off},
        rng: %CloudHypervisor.Config.RNG{src: "/dev/urandom"},
        network: lease
    }

    {:ok, writer} = Manager.start_link(state_directory: directory)
    assert {:ok, "durable-vm"} = VMManager.define(config, writer)
    GenServer.stop(writer)
    {:ok, definitions} = Store.load(directory)
    definition = definitions[config.id]

    observed = %VMManager.Status{
      phase: :stopped,
      cleanup: :ok,
      result: {:ok, %VMManager.Result{code: 0}}
    }

    assert :ok =
             Store.save(directory, %{
               config.id => %{definition | observed: observed, network: lease}
             })

    reader = """
    Application.put_env(:vm_manager, :state_directory, System.fetch_env!("VM_MANAGER_COLD_STATE"))
    {:ok, _applications} = Application.ensure_all_started(:vm_manager)
    {:ok, [status]} = VMManager.list()
    "durable-vm" = status.id
    :stopped = status.desired
    [disk, ephemeral] = status.config.disks
    "scratch.ext4" = ephemeral.name
    1024 = ephemeral.bytes
    2 = status.config.guest.contract
    3 = status.config.vsock.cid
    "/dev/urandom" = status.config.rng.src
    "/persistent" = disk.path
    false = disk.readonly
    "raw" = Atom.to_string(disk.image_type)
    ["/persistent"] = status.config.persistent_disks
    [%{tap: "tap0"}] = status.config.network.devices
    {:ok, result} = status.result
    0 = result.code
    IO.puts("cold-definition-restored")
    """

    paths =
      Enum.flat_map(:code.get_path(), fn path -> ["-pa", Path.expand(List.to_string(path))] end)

    executable = System.find_executable("elixir")
    assert is_binary(executable)

    {output, code} =
      System.cmd(executable, ["--erl", "+S 2:2"] ++ paths ++ ["--eval", reader],
        env: [{"VM_MANAGER_COLD_STATE", directory}],
        stderr_to_stdout: true
      )

    assert code == 0, output
    assert output =~ "cold-definition-restored"
  end

  test "configured real host boot identity preserves uncertain custody", %{
    directory: directory,
    config: config
  } do
    actual_identity = File.read!("/proc/sys/kernel/random/boot_id")
    source = Path.join(directory, "host-boot-id")

    definition = %Manager.Definition{
      config: config,
      desired: :stopped,
      reserved: true,
      boot_id: String.trim(actual_identity)
    }

    assert :ok = Store.save(directory, %{config.id => definition})
    File.write!(source, actual_identity)
    {:ok, manager} = Manager.start_link(state_directory: directory, boot_id_file: source)

    assert {:ok, %VMManager.Status{phase: :retained, cleanup: :unknown}} =
             VMManager.status(config.id, manager)

    assert {:error, :cleanup_uncertain} = VMManager.start(config.id, manager)
    GenServer.stop(manager)
  end

  test "missing configured host identity fails without substituting another identity", %{
    directory: directory
  } do
    source = Path.join(directory, "absent-boot-id")

    parent = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        result = Manager.start_link(state_directory: directory, boot_id_file: source)
        send(parent, {:startup_result, self(), result})
      end)

    assert_receive {:startup_result, ^worker, {:error, {:boot_identity, {^source, :enoent}}}}
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
  end

  test "unsupported declarations cannot be defined or replace a durable definition", %{
    directory: directory,
    config: config
  } do
    {:ok, manager} = Manager.start_link(state_directory: directory)
    assert {:ok, config.id} == VMManager.define(config, manager)
    assert {:ok, original} = Store.load(directory)

    for {changes, reason} <- [
          {[system: "aarch64-linux"], :unsupported_system},
          {[guest: %Config.SowerGuest{contract: 3}], :unsupported_guest},
          {[guest: %Config.SowerGuest{vsock_port: 5001}], :unsupported_guest},
          {[
             disks: [
               %VMManager.Storage.EphemeralDisk{name: "scratch.ext4", bytes: 0, filesystem: :ext4}
             ]
           ], :invalid_storage}
        ] do
      invalid = struct!(config, changes)
      new = %{invalid | id: "invalid-vm"}

      assert {:error, ^reason} = VMManager.define(new, manager)
      assert {:error, ^reason} = VMManager.update(config.id, invalid, manager)

      assert {:error, ^reason} =
               invalid
               |> Config.to_options()
               |> Keyword.put(:owner, self())
               |> VMManager.Execution.validate_options()

      assert {:ok, ^original} = Store.load(directory)
      assert {:ok, %VMManager.Status{config: ^config}} = VMManager.status(config.id, manager)
    end

    GenServer.stop(manager)
  end

  test "complete definitions and stopped intent survive manager replacement", %{
    directory: directory,
    config: config
  } do
    {:ok, first} = Manager.start_link(state_directory: directory)
    assert {:ok, "durable-vm"} = VMManager.define(config, first)
    assert :ok = VMManager.stop(config.id, first)
    GenServer.stop(first)
    {:ok, second} = Manager.start_link(state_directory: directory)
    assert {:ok, status} = VMManager.status(config.id, second)
    assert status.config == config
    assert status.desired == :stopped
    assert status.phase == :stopped
    assert status.execution == nil
    GenServer.stop(second)
  end

  test "changed host boot cleans only owned attempt files before releasing capacity", %{
    directory: directory,
    config: config
  } do
    base = Path.join(directory, "runtimes")
    attempt = "previous-attempt"
    runtime = VMManager.Guard.runtime_directory(base, attempt)
    File.mkdir_p!(runtime)
    File.write!(Path.join(runtime, "scratch.ext4"), "ephemeral scratch")
    File.write!(Path.join(runtime, "serial.log"), "serial")
    persistent = Path.join(base, "persistent.img")
    File.write!(persistent, "persistent disk")

    config = %{
      config
      | runtime_directory: base,
        persistent_disks: [persistent],
        disks: [
          %CloudHypervisor.Config.Disk{path: persistent, readonly: false, image_type: :raw},
          %VMManager.Storage.EphemeralDisk{
            name: "scratch.ext4",
            bytes: 1_048_576,
            filesystem: :ext4
          }
        ],
        serial: %CloudHypervisor.Config.Output{mode: :file, file: "serial.log"}
    }

    definition = %Manager.Definition{
      config: config,
      desired: :stopped,
      reserved: true,
      boot_id: "previous-host-boot",
      attempt: attempt,
      observed: %VMManager.Status{phase: :ready, directory: runtime, cleanup: :pending}
    }

    assert :ok = Store.save(directory, %{config.id => definition})

    certificate =
      Path.join(
        directory,
        "cleanup-" <>
          Base.url_encode64(:crypto.hash(:sha256, config.id), padding: false) <> ".etf"
      )

    assert :ok =
             Store.write_certificate(certificate, attempt, {:error, :interrupted}, :unconfirmed)

    {:ok, manager} = Manager.start_link(state_directory: directory)

    assert {:ok, %VMManager.Status{phase: :stopped, cleanup: :ok, desired: :stopped}} =
             VMManager.status(config.id, manager)

    refute File.exists?(runtime)
    assert File.read!(persistent) == "persistent disk"
    {:ok, definitions} = Store.load(directory)
    refute definitions[config.id].reserved
    assert definitions[config.id].attempts == []
    assert definitions[config.id].failure == nil
    waiting = %{config | id: "waiting", mkfs: System.find_executable("false")}
    assert {:ok, "waiting"} = VMManager.define(waiting, manager)
    assert :ok = VMManager.start(waiting.id, manager)
    assert :ok = VMManager.stop(waiting.id, manager)
    assert :ok = VMManager.update(config.id, config, manager)
    GenServer.stop(manager)
  end

  test "changed host boot retains unknown attempt files and their reservation", %{
    directory: directory,
    config: config
  } do
    base = Path.join(directory, "runtimes")
    attempt = "uncertain-attempt"
    runtime = VMManager.Guard.runtime_directory(base, attempt)
    File.mkdir_p!(runtime)
    scratch = Path.join(runtime, "scratch.ext4")
    sentinel = Path.join(runtime, "unknown")
    File.write!(scratch, "retained scratch")
    File.write!(sentinel, "retain me")

    config = %{
      config
      | runtime_directory: base,
        disks:
          config.disks ++
            [
              %VMManager.Storage.EphemeralDisk{
                name: "scratch.ext4",
                bytes: 1024,
                filesystem: :ext4
              }
            ]
    }

    definition = %Manager.Definition{
      config: config,
      desired: :stopped,
      reserved: true,
      boot_id: "previous-host-boot",
      attempt: attempt,
      observed: %VMManager.Status{phase: :ready, directory: runtime, cleanup: :pending}
    }

    assert :ok = Store.save(directory, %{config.id => definition})
    {:ok, first} = Manager.start_link(state_directory: directory)

    assert {:ok,
            %VMManager.Status{
              phase: :retained,
              cleanup: {:error, :unowned_storage}
            }} =
             VMManager.status(config.id, first)

    GenServer.stop(first)
    {:ok, second} = Manager.start_link(state_directory: directory)
    assert {:ok, %VMManager.Status{phase: :retained}} = VMManager.status(config.id, second)
    assert File.read!(scratch) == "retained scratch"
    assert File.read!(sentinel) == "retain me"
    assert {:ok, "waiting"} = VMManager.define(%{config | id: "waiting"}, second)
    assert {:error, {:capacity_exhausted, :vms}} = VMManager.start("waiting", second)
    assert {:error, :vm_not_stopped} = VMManager.remove(config.id, second)
    {:ok, definitions} = Store.load(directory)
    assert definitions[config.id].reserved
    assert definitions[config.id].desired == :stopped
    assert definitions[config.id].attempts == []
    GenServer.stop(second)
  end

  test "changed host boot never cleans external attachment directories", %{
    directory: directory,
    config: config
  } do
    base = Path.join(directory, "external")
    attempt = "external-attempt"
    runtime = VMManager.Guard.runtime_directory(base, attempt)
    File.mkdir_p!(runtime)
    scratch = Path.join(runtime, "scratch.ext4")
    File.write!(scratch, "external owner data")
    config = %{config | mode: :attach, runtime_directory: base}

    definition = %Manager.Definition{
      config: config,
      desired: :stopped,
      reserved: true,
      boot_id: "previous-host-boot",
      attempt: attempt,
      observed: %VMManager.Status{phase: :ready, directory: runtime, cleanup: :pending}
    }

    assert :ok = Store.save(directory, %{config.id => definition})
    {:ok, manager} = Manager.start_link(state_directory: directory)

    assert {:ok, %VMManager.Status{phase: :stopped, cleanup: :ok}} =
             VMManager.status(config.id, manager)

    assert File.read!(scratch) == "external owner data"
    GenServer.stop(manager)
  end

  test "stop and remove preserve disks while explicit storage deletion removes only named disks",
       %{directory: directory, config: config} do
    File.mkdir_p!(directory)
    disk = Path.join(directory, "persistent.img")
    artifact = Path.join(directory, "root.img")
    File.write!(disk, "persistent bytes")
    File.write!(artifact, "caller artifact")

    config = %{
      config
      | persistent_disks: [disk],
        disks: [
          %CloudHypervisor.Config.Disk{path: artifact, readonly: true, image_type: :raw},
          %CloudHypervisor.Config.Disk{path: disk, readonly: false, image_type: :raw}
        ]
    }

    {:ok, manager} = Manager.start_link(state_directory: directory)
    assert {:ok, _} = VMManager.define(config, manager)
    assert :ok = VMManager.stop(config.id, manager)
    assert File.read!(disk) == "persistent bytes"
    assert :ok = VMManager.delete_storage(config.id, manager)
    refute File.exists?(disk)
    assert File.read!(artifact) == "caller artifact"
    assert :ok = VMManager.remove(config.id, manager)
    assert {:error, :not_found} = VMManager.status(config.id, manager)
    GenServer.stop(manager)
  end

  test "stopped configuration update preserves identity and takes effect durably", %{
    directory: directory,
    config: config
  } do
    {:ok, manager} = Manager.start_link(state_directory: directory)
    assert {:ok, _} = VMManager.define(config, manager)
    updated = %{config | memory: 1_073_741_824}
    assert :ok = VMManager.update(config.id, updated, manager)

    assert {:error, :identity_mismatch} =
             VMManager.update(config.id, %{updated | id: "other"}, manager)

    assert {:ok, definitions} = Store.load(directory)
    assert definitions[config.id].config == updated
    GenServer.stop(manager)
  end

  test "certified cleanup remains stopped through a second manager replacement", %{
    directory: directory,
    config: config
  } do
    definition = %Manager.Definition{
      config: config,
      desired: :stopped,
      reserved: true,
      boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim(),
      attempt: "finished-attempt",
      observed: %VMManager.Status{phase: :ready, cleanup: :pending}
    }

    assert :ok = Store.save(directory, %{config.id => definition})

    certificate =
      Path.join(
        directory,
        "cleanup-" <>
          Base.url_encode64(:crypto.hash(:sha256, config.id), padding: false) <> ".etf"
      )

    assert :ok = Store.write_certificate(certificate, definition.attempt, :ok, :ok)
    {:ok, first} = Manager.start_link(state_directory: directory)

    assert {:ok, %VMManager.Status{phase: :stopped, cleanup: :ok}} =
             VMManager.status(config.id, first)

    assert {:ok, definitions} = Store.load(directory)
    refute definitions[config.id].reserved
    assert definitions[config.id].observed.phase == :stopped
    assert definitions[config.id].observed.cleanup == :ok
    GenServer.stop(first)
    {:ok, second} = Manager.start_link(state_directory: directory)

    assert {:ok, %VMManager.Status{phase: :stopped, cleanup: :ok, desired: :stopped}} =
             VMManager.status(config.id, second)

    assert :ok = VMManager.update(config.id, %{config | cpus: 2}, second)
    assert :ok = VMManager.delete_storage(config.id, second)
    assert :ok = VMManager.remove(config.id, second)
    GenServer.stop(second)
  end

  test "storage declarations reject live process identities and functions", %{config: config} do
    assert {:error, :invalid_storage} =
             Config.validate(%{config | disks: [self()]})

    assert {:error, :invalid_storage} =
             Config.validate(%{config | disks: [fn -> :ok end]})

    assert :ok = Config.validate(config)
  end

  test "durable store reports corrupt data rather than discarding ownership", %{
    directory: directory
  } do
    File.mkdir_p!(directory)
    File.write!(Path.join(directory, "definitions.etf"), "invalid")
    assert {:error, :invalid_definitions} = Store.load(directory)
  end

  test "shutdown reports uncertain VM custody while preserving other definitions", %{
    directory: directory,
    config: config
  } do
    unknown = %Manager.Definition{
      config: config,
      desired: :running,
      reserved: true,
      boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim()
    }

    healthy_config = %{config | id: "healthy"}
    healthy = %Manager.Definition{config: healthy_config}
    assert :ok = Store.save(directory, %{config.id => unknown, healthy_config.id => healthy})
    {:ok, manager} = Manager.start_link(state_directory: directory)

    assert {:error, {:cleanup_incomplete, [{"durable-vm", {:error, :cleanup_uncertain}}]}} =
             GenServer.call(manager, :prepare_shutdown)

    assert {:ok, definitions} = Store.load(directory)
    assert definitions[config.id].reserved
    refute definitions[healthy_config.id].reserved
    assert {:ok, _} = VMManager.status(healthy_config.id, manager)
    GenServer.stop(manager)
  end

  test "durable records never contain process references in failure data", %{directory: directory} do
    assert :ok =
             Store.write_certificate(
               Path.join(directory, "certificate.etf"),
               "attempt",
               {:error, {:controller, self(), make_ref()}},
               :unknown
             )

    assert {:ok, certificate} = Store.certificate(Path.join(directory, "certificate.etf"))
    assert {:error, {:controller, pid_text, reference_text}} = certificate.result
    assert is_binary(pid_text)
    assert is_binary(reference_text)
  end
end
