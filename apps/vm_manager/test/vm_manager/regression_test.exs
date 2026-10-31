defmodule VMManager.RegressionTest do
  use ExUnit.Case, async: false

  alias VMManager.{Config, Status}

  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    token = System.unique_integer([:positive])
    manager = String.to_atom("vm_manager_regression_#{token}")
    runtimes = String.to_atom("vm_manager_regression_runtimes_#{token}")
    resources = Path.join(directory, "resources")
    File.mkdir_p!(resources)
    formatter = Path.join(directory, "formatter")

    File.write!(
      formatter,
      "#!/usr/bin/env sh\nfor scratch do :; done\nprintf ready > \"$scratch.ready\"\nexec sleep 60\n"
    )

    File.chmod!(formatter, 0o700)

    options = [
      manager_name: manager,
      runtime_supervisor: runtimes,
      state_directory: Path.join(directory, "state"),
      activator_socket: "/tmp/sow-vm-absent-#{System.pid()}-#{token}.sock",
      budgets: [vms: 2, cpus: 2, memory: 2, scratch_bytes: 8192]
    ]

    {:ok, supervisor} = VMManager.Supervisor.start_link(options)
    Process.unlink(supervisor)

    on_exit(fn ->
      if Process.alive?(supervisor), do: Supervisor.stop(supervisor, :normal, :infinity)
    end)

    config = %Config{
      id: "first",
      kernel: "/unavailable/kernel",
      initrd: "/unavailable/initrd",
      root: "/unavailable/root",
      cpus: 1,
      memory: 1,
      scratch_bytes: 4096,
      boot_deadline_ms: 60_000,
      runtime_directory: resources,
      mkfs: formatter
    }

    {:ok, config: config, manager: manager, supervisor: supervisor, options: options}
  end

  test "boot reserves capacity without a command and stop waits for certified cleanup", context do
    first = define(context, "first")
    second = define(context, "second")
    third = define(context, "third")
    assert :ok = VMManager.start(first, context.manager)
    status = preparing(first, context.manager)
    assert status.desired == :running
    assert status.phase == :booting

    assert {:error, :vm_unavailable} =
             VMManager.execute(first, %VMManager.Command{path: "/bin/true"}, [], context.manager)

    assert :ok = VMManager.start(second, context.manager)
    preparing(second, context.manager)
    assert {:error, {:capacity_exhausted, :vms}} = VMManager.start(third, context.manager)
    stop_clean(first, context.manager)

    assert {:ok, %Status{desired: :stopped, cleanup: :ok}} =
             VMManager.status(first, context.manager)

    refute File.exists?(status.directory)
    assert :ok = VMManager.start(third, context.manager)
    stop_clean(second, context.manager)
    stop_clean(third, context.manager)
  end

  test "concurrent admission is atomic and distinguishes oversized requests", context do
    oversized = define(context, "oversized", cpus: 3)

    assert {:error, {:request_exceeds_capacity, :cpus}} =
             VMManager.start(oversized, context.manager)

    assert {:ok, []} = File.ls(context.config.runtime_directory)
    ids = Enum.map(1..12, &define(context, "concurrent-#{&1}"))

    results =
      ids
      |> Enum.map(fn id -> Task.async(fn -> {id, VMManager.start(id, context.manager)} end) end)
      |> Enum.map(&Task.await/1)

    admitted = for {id, :ok} <- results, do: id
    assert length(admitted) == 2

    assert Enum.count(results, fn {_id, result} ->
             result == {:error, {:capacity_exhausted, :vms}}
           end) == 10

    Enum.each(admitted, &stop_clean(&1, context.manager))
    fresh = define(context, "fresh")
    assert :ok = VMManager.start(fresh, context.manager)
    stop_clean(fresh, context.manager)
  end

  test "CPU memory and scratch reservations remain held until cleanup", context do
    for {dimension, limit} <- [cpus: 2, memory: 2, scratch_bytes: 8192] do
      first = define(context, "holding-#{dimension}", [{dimension, limit}])
      second = define(context, "waiting-#{dimension}")
      oversized = define(context, "oversized-#{dimension}", [{dimension, limit + 1}])

      assert {:error, {:request_exceeds_capacity, ^dimension}} =
               VMManager.start(oversized, context.manager)

      assert :ok = VMManager.start(first, context.manager)
      preparing(first, context.manager)

      assert {:error, {:capacity_exhausted, ^dimension}} =
               VMManager.start(second, context.manager)

      stop_clean(first, context.manager)
      assert :ok = VMManager.start(second, context.manager)
      stop_clean(second, context.manager)
    end
  end

  test "unexpected files preserve cleanup failures and reservations across manager restart",
       context do
    id = define(context, "retained", cpus: 2)
    waiting = define(context, "waiting")
    assert :ok = VMManager.start(id, context.manager)
    status = preparing(id, context.manager)

    assert {:error, {:cleanup_incomplete, {:error, {:unexpected_files, _}}}} =
             VMManager.stop(id, context.manager)

    assert File.exists?(Path.join(status.directory, "scratch.ext4.ready"))
    assert {:error, {:capacity_exhausted, :cpus}} = VMManager.start(waiting, context.manager)
    assert {:error, _} = VMManager.update(id, %{context.config | id: id}, context.manager)
    assert {:error, _} = VMManager.remove(id, context.manager)
    restart_manager(context.manager)

    assert {:ok, %Status{desired: :stopped, phase: :retained}} =
             VMManager.status(id, context.manager)

    assert {:error, {:capacity_exhausted, :cpus}} = VMManager.start(waiting, context.manager)
  end

  test "definition callers and manager restart do not tear down a live VM", context do
    parent = self()

    {caller, monitor} =
      spawn_monitor(fn ->
        id = define(context, "caller-independent")
        assert :ok = VMManager.start(id, context.manager)
        send(parent, {:started, id})
      end)

    assert_receive {:started, id}
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
    before = preparing(id, context.manager)
    restart_manager(context.manager)
    after_restart = preparing(id, context.manager)
    assert after_restart.execution == before.execution
    assert after_restart.guard == before.guard
    assert after_restart.directory == before.directory
    assert after_restart.desired == :running
    assert Process.alive?(before.guard)
    stop_clean(id, context.manager)
  end

  test "stopped definitions survive subtree restart without starting a formatter", context do
    id = define(context, "stopped")
    assert :ok = VMManager.start(id, context.manager)
    stop_clean(id, context.manager)
    Supervisor.stop(context.supervisor, :normal, :infinity)
    {:ok, replacement} = VMManager.Supervisor.start_link(context.options)
    Process.unlink(replacement)

    on_exit(fn ->
      if Process.alive?(replacement), do: Supervisor.stop(replacement, :normal, :infinity)
    end)

    assert {:ok, %Status{id: ^id, desired: :stopped, execution: nil}} =
             VMManager.status(id, context.manager)

    assert {:ok, []} = File.ls(context.config.runtime_directory)
  end

  test "guard death cannot certify teardown or free capacity", context do
    id = define(context, "guard-lost", cpus: 2)
    waiting = define(context, "waiting")
    assert :ok = VMManager.start(id, context.manager)
    status = preparing(id, context.manager)
    Process.exit(status.guard, :kill)

    eventually(fn ->
      match?(
        {:ok, %Status{phase: :retained, cleanup: :unconfirmed}},
        VMManager.status(id, context.manager)
      )
    end)

    assert File.exists?(status.directory)
    assert {:error, {:capacity_exhausted, :cpus}} = VMManager.start(waiting, context.manager)
  end

  test "boot timeout terminates the formatter before removing owned files", context do
    id = define(context, "deadline", boot_deadline_ms: 2000)
    assert :ok = VMManager.start(id, context.manager)
    status = preparing(id, context.manager)
    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))

    eventually(fn ->
      case VMManager.status(id, context.manager) do
        {:ok, %Status{cleanup: :ok, result: {:error, :timeout}}} -> true
        _ -> false
      end
    end)

    refute File.exists?(status.directory)
    eventually(fn -> not Process.alive?(status.guard) end)
  end

  test "stop certifies real formatter descendants have exited", context do
    formatter = Path.join(context.tmp_dir, "descendant-formatter")
    child_file = Path.join(context.tmp_dir, "formatter-child")

    File.write!(
      formatter,
      """
      #!/usr/bin/env sh
      for scratch do :; done
      sleep 60 &
      child=$!
      printf '%s' "$child" > '#{child_file}'
      printf ready > "$scratch.ready"
      wait "$child"
      """
    )

    File.chmod!(formatter, 0o700)
    id = define(context, "descendants", mkfs: formatter)
    assert :ok = VMManager.start(id, context.manager)
    preparing(id, context.manager)
    child = child_file |> File.read!() |> String.to_integer()
    assert File.exists?("/proc/#{child}")
    stop_clean(id, context.manager)
    eventually(fn -> not File.exists?("/proc/#{child}") end)
  end

  test "network admission fails closed without allocating runtime resources", context do
    for {mode, reason} <- [
          unfiltered: {:invalid_option, :network},
          full: :unsupported_network_config
        ] do
      id = define(context, "network-#{mode}", network: mode)
      assert :ok = VMManager.start(id, context.manager)

      eventually(fn ->
        case VMManager.status(id, context.manager) do
          {:ok,
           %Status{
             phase: :failed,
             cleanup: :ok,
             result: {:error, {:launch_failed, ^reason}},
             failure: {:vm_failed, {:error, {:launch_failed, ^reason}}}
           }} ->
            true

          _ ->
            false
        end
      end)
    end

    assert {:ok, []} = File.ls(context.config.runtime_directory)
    id = define(context, "network-capacity-released")
    assert :ok = VMManager.start(id, context.manager)
    stop_clean(id, context.manager)
  end

  test "missing network provisioner never starts a VMM and releases certified capacity",
       context do
    formatter = Path.join(context.tmp_dir, "successful-formatter")
    File.write!(formatter, "#!/usr/bin/env sh\nexit 0\n")
    File.chmod!(formatter, 0o700)

    id =
      define(context, "missing-provisioner",
        network: :full,
        network_config: :static,
        mkfs: formatter
      )

    assert :ok = VMManager.start(id, context.manager)

    eventually(fn ->
      match?(
        {:ok,
         %Status{
           cleanup: :ok,
           result: {:error, {:network_connect, :enoent}},
           vmm: nil,
           os_pid: nil
         }},
        VMManager.status(id, context.manager)
      )
    end)

    assert :ok = VMManager.stop(id, context.manager)

    assert {:ok, []} = File.ls(context.config.runtime_directory)
    next = define(context, "after-network-failure", cpus: 2)
    assert :ok = VMManager.start(next, context.manager)
    stop_clean(next, context.manager)
  end

  defp define(context, id, changes \\ []) do
    config = struct!(%{context.config | id: id}, changes)
    assert {:ok, ^id} = VMManager.define(config, context.manager)
    id
  end

  defp preparing(id, manager) do
    eventually(fn ->
      case VMManager.status(id, manager) do
        {:ok, %Status{directory: directory}} when is_binary(directory) ->
          File.exists?(Path.join(directory, "scratch.ext4.ready"))

        _ ->
          false
      end
    end)

    {:ok, status} = VMManager.status(id, manager)
    status
  end

  defp stop_clean(id, manager) do
    status = preparing(id, manager)
    File.rm!(Path.join(status.directory, "scratch.ext4.ready"))
    assert :ok = VMManager.stop(id, manager)
    refute File.exists?(status.directory)
    eventually(fn -> not Process.alive?(status.guard) end)
  end

  defp restart_manager(manager) do
    old = Process.whereis(manager)
    Process.exit(old, :kill)
    eventually(fn -> Process.whereis(manager) not in [nil, old] end)
  end

  defp eventually(fun), do: eventually(fun, System.monotonic_time(:millisecond) + 5000)

  defp eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      Process.sleep(10)
      eventually(fun, deadline)
    end
  end
end
