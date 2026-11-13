defmodule VMManager.ReconnectionTest do
  use ExUnit.Case, async: true

  test "transport interruption waits for next guest readiness without replaying a command" do
    path = Path.join(System.tmp_dir!(), "vm-manager-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    parent = self()

    peer =
      spawn_link(fn ->
        {:ok, first} = :gen_tcp.accept(listener)
        bridge(first)

        :ok =
          :gen_tcp.send(first, metadata(%{"type" => "ready", "version" => 2, "contract" => 2}))

        assert {:ok, 1, request} = request(first)
        assert request["path"] == "/bin/first"
        :gen_tcp.close(first)
        {:ok, second} = :gen_tcp.accept(listener)
        bridge(second)
        send(parent, {:awaiting_cleanup, self()})

        receive do
          :settled -> :ok
        end

        :ok =
          :gen_tcp.send(second, metadata(%{"type" => "ready", "version" => 2, "contract" => 2}))

        assert {:ok, 1, next} = request(second)
        assert next["path"] == "/bin/next"

        :ok =
          :gen_tcp.send(
            second,
            metadata(%{"type" => "exited", "version" => 2, "code" => 7, "signal" => nil})
          )

        :gen_tcp.close(second)
      end)

    io =
      spawn(fn ->
        VMManager.Guest.IO.run(parent, path, 2, System.monotonic_time(:millisecond), 5000)
      end)

    on_exit(fn -> Process.exit(io, :kill) end)
    assert_receive {:guest_ready, _}, 2_000

    command =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(command, :kill) end)
    send(io, {:execute, command, %VMManager.Command{path: "/bin/first"}, fn _, _ -> :ok end})
    assert_receive {:guest_reconnecting, ^command}
    assert_receive {:awaiting_cleanup, ^peer}
    refute_receive {:command_finished, ^command, _}
    send(peer, :settled)
    assert_receive {:command_finished, ^command, {:error, :guest_disconnected}}
    send(io, {:execute, command, %VMManager.Command{path: "/bin/next"}, fn _, _ -> :ok end})
    assert_receive {:command_finished, ^command, {:ok, %VMManager.Result{code: 7}}}
  end

  test "contract one preserves binary output and signal result" do
    path =
      Path.join(System.tmp_dir!(), "vm-contract-one-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, path}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    parent = self()
    bytes = <<0, 255, 10>>

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      bridge(socket)
      :ok = :gen_tcp.send(socket, metadata(%{"type" => "ready", "version" => 1}))
      assert {:ok, 1, %{"version" => 1, "path" => "/bin/legacy"}} = request(socket)
      :ok = :gen_tcp.send(socket, <<2, 3::unsigned-big-32, bytes::binary>>)

      :ok =
        :gen_tcp.send(
          socket,
          metadata(%{"type" => "exited", "version" => 1, "code" => nil, "signal" => 15})
        )

      :gen_tcp.close(socket)
    end)

    io =
      spawn(fn ->
        VMManager.Guest.IO.run(parent, path, 1, System.monotonic_time(:millisecond), 5000)
      end)

    on_exit(fn -> Process.exit(io, :kill) end)
    assert_receive {:guest_ready, _}, 2_000
    command = self()

    send(
      io,
      {:execute, command, %VMManager.Command{path: "/bin/legacy"},
       fn stream, output -> send(parent, {:output, stream, output}) end}
    )

    assert_receive {:output, :stdout, ^bytes}
    assert_receive {:command_finished, ^command, {:ok, %VMManager.Result{code: nil, signal: 15}}}
  end

  test "optional guest session holds admission until cancellation is certified by guest exit" do
    path = Path.join(System.tmp_dir!(), "vm-session-#{System.unique_integer([:positive])}.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, path}])

    parent = self()

    peer =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        bridge(socket)

        :ok =
          :gen_tcp.send(socket, metadata(%{"type" => "ready", "version" => 2, "contract" => 2}))

        assert {:ok, 1, %{"path" => "/bin/work"}} = request(socket)
        assert {:ok, 1, %{"type" => "cancel"}} = request(socket)
        send(parent, :cancel_received)

        receive do
          :certify_exit -> :ok
        end

        :ok =
          :gen_tcp.send(
            socket,
            metadata(%{"type" => "exited", "version" => 2, "code" => nil, "signal" => 15})
          )

        :gen_tcp.close(socket)
      end)

    config = %VMManager.Config{
      id: "session",
      kernel: "/kernel",
      guest: %VMManager.Config.SowerGuest{},
      vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: nil}
    }

    options = VMManager.Config.to_options(config)

    session =
      start_supervised!(%{
        id: VMManager.Guest.Session,
        start:
          {GenServer, :start_link,
           [
             VMManager.Guest.Session,
             {self(), self(), path, options, System.monotonic_time(:millisecond)}
           ]},
        restart: :temporary
      })

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm(path)
    end)

    assert_receive {:guest_ready, _}, 2_000
    command = %VMManager.Command{path: "/bin/work"}
    assert {:ok, handle} = GenServer.call(session, {:execute, command, [], self()})
    assert :ok = VMManager.cancel_command(handle)
    assert_receive :cancel_received
    assert %VMManager.CommandStatus{phase: :running} = VMManager.command_status(handle)
    assert {:error, :busy} = GenServer.call(session, {:execute, command, [], self()})
    send(peer, :certify_exit)
    assert {:error, :cancelled} = VMManager.await_command(handle)
    assert_receive {:vm_status, [phase: :ready]}
  end

  for contract <- [1, 2] do
    test "contract #{contract} teardown never reopens guest admission after a late terminal event" do
      contract = unquote(contract)

      path =
        Path.join(System.tmp_dir!(), "vm-terminal-#{System.unique_integer([:positive])}.sock")

      {:ok, listener} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, path}])

      parent = self()

      peer =
        spawn_link(fn ->
          {:ok, socket} = :gen_tcp.accept(listener)
          bridge(socket)

          ready =
            if contract == 1,
              do: %{"type" => "ready", "version" => 1},
              else: %{"type" => "ready", "version" => 2, "contract" => 2}

          :ok = :gen_tcp.send(socket, metadata(ready))
          assert {:ok, 1, %{"path" => "/bin/work"}} = request(socket)

          if contract == 2 do
            assert {:ok, 1, %{"type" => "cancel"}} = request(socket)
            send(parent, :cancel_observed)

            receive do
              :late_exit -> :ok
            end
          end

          :ok =
            :gen_tcp.send(
              socket,
              metadata(%{"type" => "exited", "version" => contract, "code" => 0, "signal" => nil})
            )

          :gen_tcp.close(socket)
        end)

      config = %VMManager.Config{
        id: "terminal",
        kernel: "/kernel",
        guest: %VMManager.Config.SowerGuest{contract: contract},
        vsock: %CloudHypervisor.Config.Vsock{cid: 3, socket: nil}
      }

      session =
        start_supervised!(%{
          id: VMManager.Guest.Session,
          start:
            {GenServer, :start_link,
             [
               VMManager.Guest.Session,
               {self(), self(), path, VMManager.Config.to_options(config),
                System.monotonic_time(:millisecond)}
             ]},
          restart: :temporary
        })

      on_exit(fn ->
        :gen_tcp.close(listener)
        File.rm(path)
      end)

      assert_receive {:guest_ready, _}, 2_000
      command = %VMManager.Command{path: "/bin/work"}
      assert {:ok, handle} = GenServer.call(session, {:execute, command, [], self()})

      if contract == 2 do
        assert :ok = VMManager.cancel_command(handle)
        assert_receive :cancel_observed
        assert_receive {:finish, {:error, :command_cleanup_unconfirmed}}, 6_000
        send(peer, :late_exit)
      end

      VMManager.await_command(handle)
      if contract == 1, do: assert_receive({:finish, {:ok, %VMManager.Result{}}})

      assert {:error, :vm_unavailable} =
               GenServer.call(session, {:execute, command, [], self()})
    end
  end

  defp bridge(socket) do
    assert {:ok, "CONNECT 5000\n"} = :gen_tcp.recv(socket, 0, 1_000)
    :ok = :gen_tcp.send(socket, "OK 5000\n")
    :ok = :inet.setopts(socket, packet: :raw)
  end

  defp request(socket) do
    with {:ok, <<kind, size::unsigned-big-32>>} <- :gen_tcp.recv(socket, 5, 1_000),
         {:ok, payload} <- :gen_tcp.recv(socket, size, 1_000),
         {:ok, value} <- Jason.decode(payload) do
      {:ok, kind, value}
    else
      error -> error
    end
  end

  defp metadata(value) do
    bytes = Jason.encode!(value)
    <<1, byte_size(bytes)::unsigned-big-32, bytes::binary>>
  end
end
