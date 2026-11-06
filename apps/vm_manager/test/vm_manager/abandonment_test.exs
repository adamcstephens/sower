defmodule VMManager.AbandonmentTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Network, Status, Store}

  defmodule Leases do
    def provision(id, directory) do
      with :ok <- File.write(Path.join(directory, id), "active", [:exclusive]) do
        {:ok, %Network{ownership: :managed, provider: __MODULE__, options: directory, lease: id}}
      else
        error -> error
      end
    end

    def revoke(id, directory) do
      File.write!(Path.join(directory, "revocations"), id <> "\n", [:append])
      File.write(Path.join(directory, id), "revoked")
    end

    def release(id, directory), do: File.rm(Path.join(directory, id))
  end

  setup do
    directory = Path.join(System.tmp_dir!(), "abandonment-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    runtime = VMManager.Guard.runtime_directory(Path.join(directory, "runtimes"), "old-attempt")
    File.mkdir_p!(runtime)
    File.write!(Path.join(runtime, "foreign"), "operator data")
    File.write!(Path.join(directory, "old-lease"), "active")

    network = %Network{
      ownership: :managed,
      provider: Leases,
      options: directory,
      lease: "old-lease"
    }

    persistent = Path.join(directory, "persistent.img")
    File.write!(persistent, "persistent owner data")

    config = %Config{
      id: "lost",
      kernel: "/kernel",
      restart: :never,
      persistent_disks: [persistent],
      disks: [%CloudHypervisor.Config.Disk{path: persistent, readonly: false, image_type: :raw}]
    }

    definition = %Manager.Definition{
      config: config,
      desired: :running,
      reserved: true,
      boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim(),
      beam_identity: "dead-beam",
      attempt: "old-attempt",
      network: network,
      observed: %Status{phase: :ready, directory: runtime, cleanup: :pending}
    }

    assert :ok = Store.save(directory, %{config.id => definition})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    manager =
      start_supervised!({Manager, state_directory: directory, runtime_supervisor: supervisor})

    on_exit(fn -> File.rm_rf!(directory) end)

    %{
      directory: directory,
      runtime: runtime,
      definition: definition,
      manager: manager,
      supervisor: supervisor
    }
  end

  test "explicit abandonment archives custody durably and permits a fresh attempt", context do
    assert {:ok, %Status{phase: :retained, failure: :controller_lost}} =
             VMManager.status("lost", context.manager)

    assert {:ok, archived} = VMManager.abandon_reservation("lost", context.manager)
    assert archived.config == context.definition.config
    assert archived.network == context.definition.network
    assert archived.attempt == "old-attempt"
    assert archived.boot_id == context.definition.boot_id
    assert archived.beam_identity == "dead-beam"
    assert archived.observed.directory == context.runtime
    assert Map.fetch!(archived, :abandoned_attempts) == []
    assert File.read!(Path.join(context.directory, "old-lease")) == "active"
    assert File.read!(Path.join(context.runtime, "foreign")) == "operator data"
    stop_supervised!(Manager)

    manager =
      start_supervised!(
        {Manager, state_directory: context.directory, runtime_supervisor: context.supervisor}
      )

    assert {:ok, definitions} = Store.load(context.directory)
    current = definitions["lost"]
    refute current.reserved
    assert current.desired == :stopped
    refute current.start_pending
    assert current.retry_at == nil
    assert current.network == nil
    assert Map.fetch!(current, :abandoned_attempts) == [archived]

    assert {:ok, %Status{phase: :retained, cleanup: :unknown, failure: :custody_abandoned}} =
             VMManager.status("lost", manager)

    assert :ok = VMManager.start("lost", manager)
    assert {:ok, definitions} = Store.load(context.directory)
    refute definitions["lost"].attempt == archived.attempt
    assert Map.fetch!(definitions["lost"], :abandoned_attempts) == [archived]
    assert File.read!(Path.join(context.directory, "old-lease")) == "active"
    assert File.read!(Path.join(context.runtime, "foreign")) == "operator data"
    assert :ok = VMManager.stop("lost", manager)
    assert {:error, :cleanup_uncertain} = VMManager.delete_storage("lost", manager)
    assert File.read!(Path.join(context.directory, "persistent.img")) == "persistent owner data"
    stop_supervised!(Manager)
    stop_supervised!(DynamicSupervisor)
  end

  test "abandoned definitions can be updated and explicitly removed without cleaning archived resources",
       context do
    assert {:ok, archived} = VMManager.abandon_reservation("lost", context.manager)
    updated = %{context.definition.config | cpus: 2}
    assert :ok = VMManager.update("lost", updated, context.manager)
    assert {:ok, definitions} = Store.load(context.directory)
    assert definitions["lost"].config == updated
    assert Map.fetch!(definitions["lost"], :abandoned_attempts) == [archived]
    assert {:error, :cleanup_uncertain} = VMManager.delete_storage("lost", context.manager)
    assert File.read!(Path.join(context.directory, "persistent.img")) == "persistent owner data"
    assert :ok = VMManager.remove("lost", context.manager)
    assert {:error, :not_found} = VMManager.status("lost", context.manager)
    assert File.read!(Path.join(context.directory, "old-lease")) == "active"
    assert File.read!(Path.join(context.runtime, "foreign")) == "operator data"
    assert File.read!(Path.join(context.directory, "persistent.img")) == "persistent owner data"
  end

  test "failed archive persistence keeps reservation and resources", context do
    assert {:ok, "waiting"} =
             VMManager.define(%{context.definition.config | id: "waiting"}, context.manager)

    path = Path.join(context.directory, "definitions.etf")
    original = File.read!(path)
    File.rm!(path)
    File.mkdir!(path)
    assert {:error, {:durable_store, _}} = VMManager.abandon_reservation("lost", context.manager)

    assert {:ok, %Status{phase: :retained, failure: :controller_lost}} =
             VMManager.status("lost", context.manager)

    assert {:error, {:capacity_exhausted, :vms}} = VMManager.start("waiting", context.manager)
    File.rmdir!(path)
    File.write!(path, original)
    assert {:ok, definitions} = Store.load(context.directory)
    assert definitions["lost"].reserved
    assert File.read!(Path.join(context.directory, "old-lease")) == "active"
  end

  for {name, changes} <- [
        {"another host boot", [boot_id: "previous-host"]},
        {"external attachment", [config: :attach]}
      ] do
    test "abandonment rejects #{name}", context do
      stop_supervised!(Manager)
      changes = unquote(Macro.escape(changes))

      definition =
        if changes[:config] == :attach do
          %{
            context.definition
            | config: %{context.definition.config | mode: :attach},
              desired: :stopped
          }
        else
          %{context.definition | boot_id: changes[:boot_id], network: nil}
        end

      assert :ok = Store.save(context.directory, %{"lost" => definition})

      manager =
        start_supervised!(
          {Manager, state_directory: context.directory, runtime_supervisor: context.supervisor}
        )

      assert {:ok, %Status{phase: :retained}} = VMManager.status("lost", manager)
      assert {:ok, before} = Store.load(context.directory)
      assert {:error, :not_controller_lost} = VMManager.abandon_reservation("lost", manager)
      assert {:ok, ^before} = Store.load(context.directory)
      assert File.read!(Path.join(context.directory, "old-lease")) == "active"
      assert File.read!(Path.join(context.runtime, "foreign")) == "operator data"
    end
  end

  test "failed previous-host cleanup is backed off instead of repeated each reconciliation",
       context do
    stop_supervised!(Manager)
    lease = Path.join(context.directory, "old-lease")
    File.rm!(lease)
    File.mkdir!(lease)
    definition = %{context.definition | boot_id: "previous-host"}
    assert :ok = Store.save(context.directory, %{"lost" => definition})

    manager =
      start_supervised!(
        {Manager, state_directory: context.directory, runtime_supervisor: context.supervisor}
      )

    assert {:ok, %Status{phase: :retained}} = VMManager.status("lost", manager)
    journal = Path.join(context.directory, "revocations")
    assert File.read!(journal) == "old-lease\n"
    :erlang.trace_pattern({Leases, :revoke, 2}, true, [])
    :erlang.trace(manager, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({Leases, :revoke, 2}, false, []) end)

    for _tick <- 1..20 do
      send(manager, :reconcile)
      assert {:ok, %Status{phase: :retained}} = VMManager.status("lost", manager)
    end

    assert File.read!(journal) == "old-lease\n"
    assert {:ok, definitions} = Store.load(context.directory)
    assert definitions["lost"].reserved
    assert definitions["lost"].network == definition.network
    assert_receive {:trace, ^manager, :call, {Leases, :revoke, ["old-lease", _]}}, 2000
    assert {:ok, %Status{phase: :retained}} = VMManager.status("lost", manager)
    assert File.read!(journal) == "old-lease\nold-lease\n"
  end

  test "abandonment rejects unreserved definitions", context do
    assert {:ok, "stopped"} =
             VMManager.define(%{context.definition.config | id: "stopped"}, context.manager)

    assert {:error, :not_reserved} = VMManager.abandon_reservation("stopped", context.manager)
  end
end
