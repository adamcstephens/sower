defmodule VMManager.RestartPolicyTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Store}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "vm-manager-policy-#{System.unique_integer([:positive])}")

    unique = System.unique_integer([:positive])
    manager = String.to_atom("vm_policy_manager_#{unique}")
    runtime = String.to_atom("vm_policy_runtime_#{unique}")

    options = [
      state_directory: directory,
      manager_name: manager,
      runtime_supervisor: runtime,
      budgets: [vms: 2, cpus: 2, memory: 1_073_741_824, scratch_bytes: 8_589_934_592]
    ]

    start_supervised!({VMManager.Supervisor, options})
    on_exit(fn -> File.rm_rf!(directory) end)

    config = %Config{
      id: "policy",
      kernel: "/kernel",
      initrd: "/initrd",
      root: "/root",
      mkfs: System.find_executable("false"),
      scratch_bytes: 1_048_576,
      restart_delay_ms: 1,
      restart_max_attempts: 2,
      restart_window_ms: 60_000
    }

    %{directory: directory, manager: manager, runtime: runtime, config: config}
  end

  for policy <- [:on_failure, :always] do
    test "#{policy} bounds failed VM restarts durably", context do
      config = %{context.config | restart: unquote(policy)}
      assert {:ok, _} = VMManager.define(config, context.manager)
      assert :ok = VMManager.start(config.id, context.manager)

      assert_eventually(fn ->
        {:ok, status} = VMManager.status(config.id, context.manager)
        status.failure == :restart_exhausted
      end)

      assert {:ok, definitions} = Store.load(context.directory)
      assert length(definitions[config.id].attempts) == 2
      assert definitions[config.id].failure == :restart_exhausted
      assert :ok = VMManager.stop(config.id, context.manager)
    end
  end

  test "never leaves failure visible without restart", context do
    assert {:ok, _} = VMManager.define(context.config, context.manager)
    assert :ok = VMManager.start(context.config.id, context.manager)

    assert_eventually(fn ->
      {:ok, status} = VMManager.status(context.config.id, context.manager)
      status.failure != nil
    end)

    assert {:ok, definitions} = Store.load(context.directory)
    assert definitions[context.config.id].attempts == []

    assert {:ok, %VMManager.Status{execution: nil}} =
             VMManager.status(context.config.id, context.manager)

    assert {:error, :vm_unavailable} = VMManager.await_ready(context.config.id, context.manager)

    assert {:error, :vm_unavailable} =
             VMManager.execute(
               context.config.id,
               %VMManager.Command{path: "/bin/true"},
               [],
               context.manager
             )

    assert :ok = VMManager.stop(context.config.id, context.manager)
  end

  test "lifecycle subscribers receive the definition identity and actual desired state",
       context do
    File.mkdir_p!(context.directory)
    formatter = Path.join(context.directory, "subscription-formatter")
    File.write!(formatter, "#!/usr/bin/env sh\nexec sleep 60\n")
    File.chmod!(formatter, 0o700)
    config = %{context.config | mkfs: formatter}
    id = config.id
    assert {:ok, ^id} = VMManager.define(config, context.manager)
    assert :ok = VMManager.subscribe(id, context.manager)
    assert :ok = VMManager.start(id, context.manager)

    assert_receive {:vm_manager, ^id,
                    %VMManager.Status{phase: :booting, desired: :running} = booting},
                   2000

    assert booting.id == id
    assert booting.execution_id == id
    assert booting.config.id == id
    assert booting.config.root == config.root
    assert booting.failure == nil
    assert :ok = VMManager.stop(id, context.manager)

    assert_receive {:vm_manager, ^id,
                    %VMManager.Status{phase: :stopped, desired: :stopped} = stopped},
                   2000

    assert stopped.id == id
    assert stopped.execution_id == id
    assert stopped.config == booting.config
    assert stopped.failure == nil
    assert stopped.cleanup == :ok
    assert stopped.execution == nil
    assert {:error, :vm_unavailable} = VMManager.await_ready(id, context.manager)

    assert {:error, :vm_unavailable} =
             VMManager.execute(id, %VMManager.Command{path: "/bin/true"}, [], context.manager)

    assert_eventually(fn -> DynamicSupervisor.count_children(context.runtime).active == 0 end)
    assert {:ok, %VMManager.Status{execution: nil}} = VMManager.status(id, context.manager)
    assert {:error, :vm_unavailable} = VMManager.await_ready(id, context.manager)

    assert {:error, :vm_unavailable} =
             VMManager.execute(id, %VMManager.Command{path: "/bin/true"}, [], context.manager)
  end

  test "stop acknowledges durable finalization and controller retirement before immediate mutations",
       context do
    File.mkdir_p!(context.directory)
    formatter = Path.join(context.directory, "stop-formatter")
    File.write!(formatter, "#!/usr/bin/env sh\nexec sleep 60\n")
    File.chmod!(formatter, 0o700)
    disk = Path.join(context.directory, "persistent.img")
    File.write!(disk, "owned persistent data")
    config = %{context.config | mkfs: formatter, persistent_disks: [disk]}
    assert {:ok, _} = VMManager.define(config, context.manager)
    assert :ok = VMManager.start(config.id, context.manager)
    :ok = :sys.suspend(context.runtime)
    stopping = Task.async(fn -> VMManager.stop(config.id, context.manager) end)

    try do
      assert_eventually(fn ->
        {:ok, definitions} = Store.load(context.directory)
        not definitions[config.id].reserved
      end)

      assert Task.yield(stopping, 100) == nil
    after
      :ok = :sys.resume(context.runtime)
    end

    assert :ok = Task.await(stopping)
    {:ok, definitions} = Store.load(context.directory)
    definition = definitions[config.id]
    assert definition.desired == :stopped
    assert definition.observed.phase == :stopped
    assert definition.observed.cleanup == :ok
    assert definition.observed.execution == nil
    refute definition.reserved
    assert :ok = VMManager.update(config.id, config, context.manager)
    assert :ok = VMManager.delete_storage(config.id, context.manager)
    refute File.exists?(disk)
    assert :ok = VMManager.remove(config.id, context.manager)
    replacement = %{config | id: "replacement", persistent_disks: []}
    assert {:ok, _} = VMManager.define(replacement, context.manager)
    assert :ok = VMManager.start(replacement.id, context.manager)
    assert :ok = VMManager.stop(replacement.id, context.manager)
    assert :ok = VMManager.remove(replacement.id, context.manager)
  end

  test "shutdown fences queued reconciliation without changing durable running intent", context do
    File.mkdir_p!(context.directory)
    formatter = Path.join(context.directory, "slow-formatter")
    File.write!(formatter, "#!/usr/bin/env sh\nexec sleep 60\n")
    File.chmod!(formatter, 0o700)
    config = %{context.config | restart: :always, mkfs: formatter}
    assert {:ok, _} = VMManager.define(config, context.manager)
    assert :ok = VMManager.start(config.id, context.manager)
    assert {:ok, before_shutdown} = VMManager.status(config.id, context.manager)
    assert :ok = GenServer.call(context.manager, :prepare_shutdown)
    send(context.manager, :reconcile)
    send(context.manager, :tick)
    Process.sleep(250)
    assert {:ok, definitions} = Store.load(context.directory)
    definition = definitions[config.id]
    assert definition.desired == :running
    assert definition.failure == nil
    assert definition.attempts == []
    refute definition.reserved
    assert {:ok, after_shutdown} = VMManager.status(config.id, context.manager)
    assert after_shutdown.execution == nil
    assert [{_id, runtime, :worker, _modules}] = DynamicSupervisor.which_children(context.runtime)
    assert runtime == before_shutdown.execution
    assert {:error, :draining} = VMManager.start(config.id, context.manager)
    assert {:error, :draining} = VMManager.update(config.id, config, context.manager)
  end

  test "uncertified same-host custody survives manager replacement and blocks duplicate launch",
       context do
    {:ok, boot_id} = File.read("/proc/sys/kernel/random/boot_id")

    definition = %VMManager.Manager.Definition{
      config: context.config,
      desired: :running,
      reserved: true,
      boot_id: String.trim(boot_id),
      attempt: "lost-controller"
    }

    directory = Path.join(context.directory, "lost")
    assert :ok = Store.save(directory, %{context.config.id => definition})

    {:ok, first} =
      VMManager.Manager.start_link(
        state_directory: directory,
        runtime_supervisor: context.runtime
      )

    GenServer.stop(first)

    {:ok, manager} =
      VMManager.Manager.start_link(
        state_directory: directory,
        runtime_supervisor: context.runtime
      )

    assert_eventually(fn ->
      {:ok, status} = VMManager.status(context.config.id, manager)
      status.phase == :retained
    end)

    assert {:error, :cleanup_uncertain} = VMManager.start(context.config.id, manager)
    assert {:error, :cleanup_uncertain} = VMManager.stop(context.config.id, manager)

    assert {:error, :vm_not_stopped} =
             VMManager.update(context.config.id, context.config, manager)

    GenServer.stop(manager)
  end

  for policy <- [:never, :on_failure, :always], outcome <- [:normal, :failed] do
    result =
      if outcome == :normal,
        do: {:ok, {:vmm_exited, {:exit_status, 0}}},
        else: {:error, {:vmm_exited, {:exit_status, 1}}}

    attempts =
      if policy == :always or (policy == :on_failure and outcome == :failed), do: 1, else: 0

    test "#{policy} distinguishes #{outcome} VM termination during recovery", context do
      policy = unquote(policy)
      outcome = unquote(outcome)
      directory = Path.join(context.directory, "#{policy}-#{outcome}")
      config = %{context.config | restart: policy, restart_delay_ms: 60_000}

      result = unquote(Macro.escape(result))

      definition = %VMManager.Manager.Definition{
        config: config,
        desired: :running,
        reserved: true,
        boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim(),
        attempt: "certified-attempt"
      }

      assert :ok = Store.save(directory, %{config.id => definition})

      certificate_path =
        Path.join(
          directory,
          "cleanup-" <>
            Base.url_encode64(:crypto.hash(:sha256, config.id), padding: false) <> ".etf"
        )

      assert :ok = Store.write_certificate(certificate_path, "certified-attempt", result, :ok)

      {:ok, manager} =
        VMManager.Manager.start_link(
          state_directory: directory,
          runtime_supervisor: context.runtime
        )

      assert_eventually(fn ->
        {:ok, definitions} = Store.load(directory)
        not definitions[config.id].reserved
      end)

      {:ok, definitions} = Store.load(directory)
      assert length(definitions[config.id].attempts) == unquote(attempts)
      assert definitions[config.id].desired == :running
      assert :ok = VMManager.stop(config.id, manager)
      GenServer.stop(manager)
    end
  end

  defp assert_eventually(predicate, attempts \\ 200)
  defp assert_eventually(predicate, 0), do: assert(predicate.())

  defp assert_eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(25)
      assert_eventually(predicate, attempts - 1)
    end
  end
end
