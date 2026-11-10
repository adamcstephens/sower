defmodule VMManager.LifecycleBoundaryTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Network, Status, Store}

  defmodule Lease do
    def provision(_id, options) do
      path = options[:path]
      :ok = File.write(path, "allocated")

      {:ok,
       %VMManager.Network{
         ownership: :managed,
         provider: __MODULE__,
         options: options,
         lease: path
       }}
    end

    def revoke(path, _options), do: File.write(path <> ".revoked", "revoked")

    def release(path, _options) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
      end
    end
  end

  @moduletag :tmp_dir

  test "a stopped running waiter cannot succeed on a delayed Running observation", %{
    tmp_dir: directory
  } do
    {config, peer} = attached_vm(directory, true)
    execution = start_supervised!({VMManager.Execution, Config.to_options(config)})
    assert_receive {:native_info_waiting, server}
    waiter = Task.async(fn -> GenServer.call(execution, :await_running, :infinity) end)
    assert Task.yield(waiter, 100) == nil
    GenServer.cast(execution, {:stop, %VMManager.Stop{mode: :force}})
    assert %Status{phase: :stopping} = GenServer.call(execution, :status)
    send(server, :reply_running)
    assert {:error, _reason} = Task.await(waiter, 5_000)
    assert :ok = GenServer.call(execution, {:stop, %VMManager.Stop{mode: :force}}, 5_000)
    Task.await(peer)
  end

  test "attachment checkpoints managed custody before accepting Running and restores it after host change",
       %{tmp_dir: directory} do
    {config, peer} = attached_vm(directory, false)
    lease = Path.join(directory, "managed-lease")
    File.write!(lease, "allocated")
    network = %Network{ownership: :managed, provider: Lease, options: [path: lease], lease: lease}
    config = %{config | network: network}
    runtime = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    state_directory = Path.join(directory, "state")

    manager =
      start_supervised!({Manager, state_directory: state_directory, runtime_supervisor: runtime})

    assert {:ok, id} = VMManager.define(config, manager)
    assert :ok = VMManager.start(id, manager)
    assert {:ok, %Status{running: true}} = VMManager.await_running(id, manager)
    assert {:ok, definitions} = Store.load(state_directory)
    definition = definitions[id]
    assert definition.network == network

    recovery_directory = Path.join(directory, "recovery")
    restored = %{definition | desired: :stopped, boot_id: "previous-host"}
    assert :ok = Store.save(recovery_directory, %{id => restored})

    recovery =
      start_supervised!(
        Supervisor.child_spec(
          {Manager, state_directory: recovery_directory, runtime_supervisor: runtime},
          id: :recovery
        )
      )

    assert {:ok, %Status{phase: :stopped, cleanup: :ok}} = VMManager.status(id, recovery)
    assert File.exists?(lease <> ".revoked")
    refute File.exists?(lease)
    stop_supervised!(:recovery)
    assert :ok = VMManager.stop(id, manager)
    Task.await(peer)
  end

  test "a released managed attachment requires a fresh stopped update before starting again", %{
    tmp_dir: directory
  } do
    {config, peer} = attached_vm(directory, false)
    lease = Path.join(directory, "consumed-lease")
    File.write!(lease, "allocated")
    network = %Network{ownership: :managed, provider: Lease, options: [path: lease], lease: lease}
    config = %{config | network: network}
    runtime = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    state_directory = Path.join(directory, "consumed-state")

    manager =
      start_supervised!({Manager, state_directory: state_directory, runtime_supervisor: runtime})

    assert {:ok, id} = VMManager.define(config, manager)
    assert :ok = VMManager.start(id, manager)
    assert {:ok, %Status{running: true}} = VMManager.await_running(id, manager)
    assert :ok = VMManager.stop(id, manager)
    Task.await(peer)
    refute File.exists?(lease)
    assert {:error, :attachment_lease_consumed} = VMManager.start(id, manager)
    assert {:error, :attachment_lease_consumed} = VMManager.update(id, config, manager)

    {fresh_config, fresh_peer} = attached_vm(directory, false)
    fresh_lease = Path.join(directory, "fresh-lease")
    File.write!(fresh_lease, "allocated")
    fresh_network = %{network | lease: fresh_lease, options: [path: fresh_lease]}
    fresh_config = %{fresh_config | network: fresh_network}
    assert :ok = VMManager.update(id, fresh_config, manager)
    assert :ok = VMManager.start(id, manager)
    assert {:ok, %Status{running: true}} = VMManager.await_running(id, manager)
    assert :ok = VMManager.stop(id, manager)
    Task.await(fresh_peer)
    refute File.exists?(fresh_lease)
  end

  defp attached_vm(_directory, gated) do
    control =
      Path.join(System.tmp_dir!(), "vm-boundary-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, control}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(control)
    end)

    config = %Config{id: "attached", kernel: "/kernel", mode: :attach, control_endpoint: control}

    native = %{
      "payload" => %{"kernel" => "/kernel", "cmdline" => " sower.vm.id=attached"},
      "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
      "memory" => %{"size" => config.memory},
      "disks" => [],
      "net" => []
    }

    info = fn state ->
      Jason.encode!(%{
        "state" => state,
        "device_tree" => nil,
        "config" => native,
        "memory_actual_size" => config.memory
      })
    end

    parent = self()

    peer =
      Task.async(fn ->
        exchange = fn exchange, state, gated ->
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
          headers(socket)

          if gated do
            send(parent, {:native_info_waiting, self()})

            receive do
              :reply_running -> :ok
            end
          end

          {body, next_state} =
            case request do
              "GET /api/v1/vm.info HTTP/1.1\r\n" -> {info.(state), state}
              "PUT /api/v1/vm.power-button HTTP/1.1\r\n" -> {"", "Created"}
              "PUT /api/v1/vm.shutdown HTTP/1.1\r\n" -> {"", "Created"}
            end

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-length: ",
              to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

          :gen_tcp.close(socket)
          unless state == "Created", do: exchange.(exchange, next_state, false)
        end

        exchange.(exchange, "Running", gated)
      end)

    {config, peer}
  end

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> headers(socket)
    end
  end
end
