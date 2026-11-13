defmodule VMManager.ManagerIntentTest do
  use ExUnit.Case, async: false

  alias VMManager.{Config, Store}

  setup do
    unique = System.unique_integer([:positive])
    directory = Path.join(System.tmp_dir!(), "vm-manager-intent-#{unique}")
    manager = String.to_atom("vm_intent_manager_#{unique}")
    runtime = String.to_atom("vm_intent_runtime_#{unique}")
    File.mkdir_p!(directory)
    formatter = Path.join(directory, "formatter")
    ready = Path.join(directory, "formatter-ready")
    assert {"", 0} = System.cmd("mkfifo", [ready])
    File.write!(formatter, "#!/usr/bin/env sh\nprintf ready > '#{ready}'\nexec sleep 60\n")
    File.chmod!(formatter, 0o700)

    {:ok, reader, reader_os_pid} =
      Rexec.run_link([System.find_executable("cat"), ready], owner: self())

    Process.unlink(reader)
    reader_monitor = Process.monitor(reader)

    on_exit(fn ->
      if Process.alive?(reader), do: Rexec.kill_tree(reader, :sigkill)
      File.rm_rf!(directory)
    end)

    supervisor =
      start_supervised!(
        {VMManager.Supervisor,
         state_directory: directory,
         manager_name: manager,
         runtime_supervisor: runtime,
         budgets: [vms: 1, cpus: 1, memory: 536_870_912, scratch_bytes: 4_294_967_296]}
      )

    config = %Config{
      id: "intent",
      kernel: "/kernel",
      initrd: "/initrd",
      disks: [
        %VMManager.Storage.EphemeralDisk{
          name: "scratch.ext4",
          bytes: 1_048_576,
          filesystem: :ext4
        }
      ],
      mkfs: formatter,
      restart: :never
    }

    assert {:ok, "intent"} = VMManager.define(config, manager)
    assert :ok = VMManager.subscribe(config.id, manager)
    assert :ok = VMManager.start(config.id, manager)
    assert formatter_ready(reader, reader_monitor, reader_os_pid, manager) == "ready"
    assert {:ok, status} = VMManager.status(config.id, manager)
    guard = :sys.get_state(status.execution).guard
    true = :erlang.suspend_process(guard)

    %{
      directory: directory,
      manager: manager,
      runtime: runtime,
      supervisor: supervisor,
      config: config,
      execution: status.execution,
      guard: guard
    }
  end

  for replace <- [false, true] do
    test "explicit start survives stopping cleanup with manager replacement #{replace}",
         context do
      try do
        stop = request_stop(context)
        assert :ok = VMManager.start(context.config.id, context.manager)
        if unquote(replace), do: replace_manager(context)

        assert {:ok, definitions} = Store.load(context.directory)
        assert definitions[context.config.id].desired == :running
        assert definitions[context.config.id].reserved
        assert [{_, execution, :worker, _}] = DynamicSupervisor.which_children(context.runtime)
        assert execution == context.execution

        true = :erlang.resume_process(context.guard)

        assert_receive {:vm_manager, "intent",
                        %VMManager.Status{execution: replacement, phase: :booting}}
                       when replacement != context.execution and not is_nil(replacement),
                       2000

        unless unquote(replace), do: assert_receive({^stop, :ok}, 2000)
        assert :ok = VMManager.stop(context.config.id, context.manager)
      after
        resume_guard(context.guard)
      end
    end
  end

  test "a later explicit stop cancels the queued explicit start", context do
    try do
      first = request_stop(context)
      assert :ok = VMManager.start(context.config.id, context.manager)
      last = request_stop(context)
      true = :erlang.resume_process(context.guard)
      assert_receive {^first, :ok}, 2000
      assert_receive {^last, :ok}, 2000
      assert {:ok, definitions} = Store.load(context.directory)
      assert definitions[context.config.id].desired == :stopped
      refute definitions[context.config.id].reserved
      assert DynamicSupervisor.count_children(context.runtime).active == 0
    after
      resume_guard(context.guard)
    end
  end

  test "replacement enforces durable stopped intent against a surviving controller", context do
    try do
      assert :ok = Supervisor.terminate_child(context.supervisor, VMManager.Manager)
      assert {:ok, definitions} = Store.load(context.directory)
      definition = definitions[context.config.id]
      assert definition.reserved

      assert :ok =
               Store.save(context.directory, %{
                 context.config.id => %{definition | desired: :stopped}
               })

      assert {:ok, _} = Supervisor.restart_child(context.supervisor, VMManager.Manager)
      send(context.manager, :reconcile)
      assert {:ok, status} = VMManager.status(context.config.id, context.manager)
      assert status.desired == :stopped
      assert :stopping == GenServer.call(context.execution, :status).phase
      assert {:ok, retained} = Store.load(context.directory)
      assert retained[context.config.id].reserved

      true = :erlang.resume_process(context.guard)
      assert :ok = VMManager.stop(context.config.id, context.manager)
      assert {:ok, stopped} = Store.load(context.directory)
      refute stopped[context.config.id].reserved
      assert stopped[context.config.id].observed.cleanup == :ok
    after
      resume_guard(context.guard)
    end
  end

  test "explicit start replaces a certified terminal controller exactly once", context do
    reference = make_ref()
    caller = self()
    :ok = :sys.suspend(context.manager)

    try do
      :sys.replace_state(context.manager, fn state ->
        if timer = Process.delete(:reconcile_timer), do: Process.cancel_timer(timer)
        drain_reconciliation()
        send(self(), {:"$gen_call", {caller, reference}, {:start, context.config.id}})
        state
      end)

      true = :erlang.resume_process(context.guard)
      assert :ok = GenServer.call(context.execution, :stop)

      assert %VMManager.Status{cleanup: :ok, phase: :stopped} =
               GenServer.call(context.execution, :status)

      assert {:ok, definitions} = Store.load(context.directory)
      assert definitions[context.config.id].reserved
      :ok = :sys.resume(context.manager)
      assert_receive {^reference, :ok}, 5_000
      send(context.manager, :reconcile)

      assert_receive {:vm_manager, "intent",
                      %VMManager.Status{execution: replacement, phase: :booting}}
                     when replacement != context.execution and not is_nil(replacement),
                     2000

      assert :ok = VMManager.start(context.config.id, context.manager)
      send(context.manager, :reconcile)

      assert {:ok, %VMManager.Status{execution: ^replacement}} =
               VMManager.status(context.config.id, context.manager)

      assert [{_, ^replacement, :worker, _}] = DynamicSupervisor.which_children(context.runtime)
      assert :ok = VMManager.stop(context.config.id, context.manager)
    after
      :ok = :sys.resume(context.manager)
      resume_guard(context.guard)
    end
  end

  test "abandonment rejects a live controller without releasing its reservation", context do
    try do
      assert {:ok, before} = Store.load(context.directory)

      assert {:error, :controller_active} =
               VMManager.abandon_reservation(context.config.id, context.manager)

      assert {:ok, ^before} = Store.load(context.directory)

      assert {:ok, %VMManager.Status{execution: execution}} =
               VMManager.status(context.config.id, context.manager)

      assert execution == context.execution
    after
      resume_guard(context.guard)
    end
  end

  test "certified stop stays stopped while Registry retains the dead controller", context do
    key = {:registry_partition, make_ref()}
    {:ok, partition} = Registry.register(VMManager.Registry, key, nil)
    Registry.unregister(VMManager.Registry, key)
    :ok = :sys.suspend(partition)

    try do
      true = :erlang.resume_process(context.guard)
      assert :ok = VMManager.stop(context.config.id, context.manager)
      refute Process.alive?(context.execution)

      assert [{execution, _}] =
               Registry.lookup(VMManager.Registry, {context.directory, context.config.id})

      assert execution == context.execution
      assert {:ok, definitions} = Store.load(context.directory)
      refute definitions[context.config.id].reserved
      assert definitions[context.config.id].observed.cleanup == :ok

      assert {:ok, %VMManager.Status{phase: :stopped, cleanup: :ok}} =
               VMManager.status(context.config.id, context.manager)
    after
      :ok = :sys.resume(partition)
      resume_guard(context.guard)
    end
  end

  test "start rejects a live retained controller without changing durable intent", context do
    try do
      assert {:ok, status} = VMManager.status(context.config.id, context.manager)
      foreign = Path.join(status.directory, "foreign")
      File.write!(foreign, "not owned")
      stop = request_stop(context)
      true = :erlang.resume_process(context.guard)
      assert_receive {^stop, {:error, {:cleanup_incomplete, _cleanup}}}, 2000

      assert {:ok, %VMManager.Status{phase: :retained}} =
               VMManager.status(context.config.id, context.manager)

      assert [{_, execution, :worker, _}] = DynamicSupervisor.which_children(context.runtime)
      assert execution == context.execution
      path = Path.join(context.directory, "definitions.etf")
      before = File.read!(path)
      assert {:ok, metadata} = File.stat(path)
      assert {:error, :cleanup_uncertain} = VMManager.start(context.config.id, context.manager)
      assert File.read!(path) == before
      assert {:ok, unchanged} = File.stat(path)
      assert unchanged.inode == metadata.inode
      assert {:ok, definitions} = Store.load(context.directory)
      refute definitions[context.config.id].start_pending
      assert definitions[context.config.id].desired == :stopped
      assert definitions[context.config.id].reserved
      assert File.read!(foreign) == "not owned"
    after
      resume_guard(context.guard)
    end
  end

  defp drain_reconciliation do
    receive do
      message when message in [:tick, :reconcile] -> drain_reconciliation()
    after
      0 -> :ok
    end
  end

  defp request_stop(context) do
    reference = make_ref()
    send(context.manager, {:"$gen_call", {self(), reference}, {:stop, context.config.id}})

    assert {:ok, %VMManager.Status{desired: :stopped}} =
             VMManager.status(context.config.id, context.manager)

    reference
  end

  defp replace_manager(context) do
    assert :ok = Supervisor.terminate_child(context.supervisor, VMManager.Manager)
    assert {:ok, _} = Supervisor.restart_child(context.supervisor, VMManager.Manager)
    assert :ok = VMManager.subscribe(context.config.id, context.manager)
  end

  defp formatter_ready(reader, monitor, os_pid, manager, bytes \\ "") do
    receive do
      {:stdout, ^os_pid, more} ->
        formatter_ready(reader, monitor, os_pid, manager, bytes <> more)

      {:DOWN, ^monitor, :process, ^reader, :normal} ->
        bytes

      {:DOWN, ^monitor, :process, ^reader, reason} ->
        flunk(
          "formatter reader failed: #{inspect(reason)}; status=#{inspect(VMManager.status("intent", manager))}"
        )
    after
      2000 ->
        status = VMManager.status("intent", manager)

        execution =
          case status do
            {:ok, %{execution: execution}} when is_pid(execution) -> :sys.get_state(execution)
            _ -> nil
          end

        flunk(
          "formatter readiness missing: status=#{inspect(status)} execution=#{inspect(execution)} reader=#{inspect(Process.info(reader))} output=#{inspect(bytes)}"
        )
    end
  end

  defp resume_guard(guard) do
    if Process.alive?(guard) and Process.info(guard, :status) == {:status, :suspended} do
      true = :erlang.resume_process(guard)
    end
  end
end
