defmodule VMManager.TransientPersistenceTest do
  use ExUnit.Case, async: false
  alias VMManager.{Config, Manager, Status}

  test "unreserved definitions do not read or hash cleanup certificates during reconciliation" do
    directory =
      Path.join(System.tmp_dir!(), "unreserved-reconcile-#{System.unique_integer([:positive])}")

    manager = start_supervised!({Manager, state_directory: directory})
    on_exit(fn -> File.rm_rf!(directory) end)
    assert {:ok, "idle"} = VMManager.define(%Config{id: "idle", kernel: "/kernel"}, manager)
    :erlang.trace_pattern({File, :read, 1}, true, [])
    :erlang.trace_pattern({:crypto, :hash, 2}, true, [])
    :erlang.trace(manager, true, [:call])

    on_exit(fn ->
      :erlang.trace_pattern({File, :read, 1}, false, [])
      :erlang.trace_pattern({:crypto, :hash, 2}, false, [])
    end)

    for _tick <- 1..3 do
      send(manager, :reconcile)
      assert {:ok, %Status{phase: :stopped}} = VMManager.status("idle", manager)
    end

    delivered = :erlang.trace_delivered(manager)
    assert_receive {:trace_delivered, ^manager, ^delivered}
    refute_receive {:trace, ^manager, :call, {File, :read, _}}, 0
    refute_receive {:trace, ^manager, :call, {:crypto, :hash, _}}, 0
  end

  test "observed ready command ready phases do not sync durable definitions" do
    directory =
      Path.join(System.tmp_dir!(), "transient-persistence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    control = Path.join(directory, "control.sock")
    guest = Path.join(directory, "guest.sock")

    {:ok, native_listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, control}])

    {:ok, guest_listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, guest}])

    on_exit(fn ->
      :gen_tcp.close(native_listener)
      :gen_tcp.close(guest_listener)
      File.rm_rf!(directory)
    end)

    config = %Config{
      id: "transient",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: control,
      guest: %Config.SowerGuest{},
      vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: guest}
    }

    native_config = %{
      "payload" => %{"kernel" => "/kernel", "cmdline" => " sower.vm.id=transient"},
      "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
      "memory" => %{"size" => 536_870_912},
      "disks" => [],
      "net" => [],
      "vsock" => %{"cid" => 3, "socket" => guest}
    }

    parent = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, socket} = :gen_tcp.accept(native_listener)
         native_loop(socket, native_config, "Running")
       end}
    )

    peer =
      start_supervised!(
        Supervisor.child_spec(
          {Task,
           fn ->
             {:ok, socket} = :gen_tcp.accept(guest_listener)
             assert {:ok, "CONNECT 5000\n"} = :gen_tcp.recv(socket, 0, 1000)
             :ok = :gen_tcp.send(socket, "OK 5000\n")
             :ok = :inet.setopts(socket, packet: :raw)
             send(parent, {:guest_connected, self()})

             receive do
               :ready -> :ok
             end

             :ok =
               :gen_tcp.send(
                 socket,
                 metadata(%{"type" => "ready", "version" => 2, "contract" => 2})
               )

             assert {:ok, <<1, size::unsigned-big-32>>} = :gen_tcp.recv(socket, 5, 1000)
             assert {:ok, payload} = :gen_tcp.recv(socket, size, 1000)
             assert %{"path" => "/bin/held"} = Jason.decode!(payload)
             send(parent, {:command_received, self()})

             receive do
               :finish -> :ok
             end

             :ok =
               :gen_tcp.send(
                 socket,
                 metadata(%{"type" => "exited", "version" => 2, "code" => 0, "signal" => nil})
               )

             receive do
               :close -> :gen_tcp.close(socket)
             end
           end},
          id: :guest_peer
        )
      )

    runtime = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    manager =
      start_supervised!({Manager, state_directory: directory, runtime_supervisor: runtime})

    assert {:ok, "transient"} = VMManager.define(config, manager)
    assert :ok = VMManager.start("transient", manager)

    receive do
      {:guest_connected, ^peer} -> :ok
    after
      2000 ->
        flunk(
          "guest connection missing: #{inspect(VMManager.status("transient", manager))}; peer=#{inspect(Process.info(peer))}"
        )
    end

    assert {:ok, %Status{running: true}} = VMManager.await_running("transient", manager)
    send(manager, :reconcile)
    assert {:ok, %Status{running: true}} = VMManager.status("transient", manager)
    :erlang.trace_pattern({:file, :sync, 1}, true, [])
    :erlang.trace(manager, true, [:call])
    on_exit(fn -> :erlang.trace_pattern({:file, :sync, 1}, false, []) end)
    send(peer, :ready)
    assert {:ok, %Status{phase: :ready}} = VMManager.await_ready("transient", manager)
    reconcile_phase(manager, :ready)

    assert {:ok, command} =
             VMManager.execute("transient", %VMManager.Command{path: "/bin/held"}, [], manager)

    assert_receive {:command_received, ^peer}, 1000
    reconcile_phase(manager, :running_command)
    send(peer, :finish)
    assert {:ok, %VMManager.Result{code: 0}} = VMManager.await_command(command)
    reconcile_phase(manager, :ready)
    delivered = :erlang.trace_delivered(manager)
    assert_receive {:trace_delivered, ^manager, ^delivered}
    refute_receive {:trace, ^manager, :call, {:file, :sync, _}}, 0
    :erlang.trace(manager, false, [:call])
    assert :ok = VMManager.stop("transient", manager)
    send(peer, :close)
  end

  defp reconcile_phase(manager, phase) do
    send(manager, :reconcile)
    assert {:ok, %Status{phase: ^phase}} = VMManager.status("transient", manager)
  end

  defp metadata(value) do
    bytes = Jason.encode!(value)
    <<1, byte_size(bytes)::unsigned-big-32, bytes::binary>>
  end

  defp native_loop(socket, config, state) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, request} ->
        headers(socket)
        stopping = String.starts_with?(request, "PUT /api/v1/vm.power-button ")
        state = if stopping, do: "Created", else: state

        body =
          if stopping,
            do: "",
            else:
              Jason.encode!(%{
                "state" => state,
                "device_tree" => nil,
                "memory_actual_size" => 536_870_912,
                "config" => config
              })

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\ncontent-length: ",
            to_string(byte_size(body)),
            "\r\n\r\n",
            body
          ])

        native_loop(socket, config, state)

      {:error, :closed} ->
        :ok
    end
  end

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 1000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> headers(socket)
    end
  end
end
