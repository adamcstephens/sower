defmodule Garden.VM.CLITest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  test "caller death during boot removes only the disposable definition after cleanup", %{
    tmp_dir: directory,
    manager: manager
  } do
    marker = Path.join(directory, "formatter-ready")
    gate = Path.join(directory, "formatter-gate")
    {"", 0} = System.cmd("mkfifo", [marker, gate])
    formatter = Path.join(directory, "formatter")

    File.write!(formatter, "#!/usr/bin/env sh\nprintf ready > '#{marker}'\nexec cat '#{gate}'\n")
    File.chmod!(formatter, 0o700)

    image = %Garden.Image{
      directory: directory,
      kernel: "/kernel",
      initrd: "/initrd",
      root: "/root",
      cmdline: "",
      contract: 2
    }

    persistent = "persistent-#{System.unique_integer([:positive])}"

    assert {:ok, ^persistent} =
             VMManager.define(%VMManager.Config{id: persistent, kernel: "/kernel"}, manager)

    on_exit(fn -> cleanup(fn -> VMManager.remove(persistent, manager) end) end)

    reader = fifo_reader(marker)

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Garden.VM.CLI.run(image, %VMManager.Command{path: "/bin/true"},
          manager: manager,
          mkfs: formatter,
          scratch_bytes: 4096,
          runtime_directory: Path.join(directory, "runtime")
        )
      end)

    assert fifo_output(reader) == "ready"
    assert {:ok, definitions} = VMManager.list(manager)

    disposable =
      Enum.find(definitions, &(&1.config.runtime_directory == Path.join(directory, "runtime")))

    assert disposable
    assert {:ok, status} = VMManager.status(disposable.id, manager)

    on_exit(fn ->
      if Process.alive?(caller), do: Process.exit(caller, :kill)
      cleanup(fn -> cleanup_vm(disposable.id, manager) end)
    end)

    execution = Process.monitor(status.execution)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^execution, :process, _, _}, 5_000
    await_removed(disposable.id, manager, System.monotonic_time(:millisecond) + 5_000)
    refute File.exists?(status.directory)
    assert {:ok, %VMManager.Status{desired: :stopped}} = VMManager.status(persistent, manager)
  end

  for outcome <- [:caller_down, 0, 23] do
    test "running disposable command cleans custody for #{outcome}", %{
      tmp_dir: directory,
      manager: manager
    } do
      outcome = unquote(outcome)
      marker = Path.join(directory, "native-ready")
      gate = Path.join(directory, "native-gate")
      {"", 0} = System.cmd("mkfifo", [marker, gate])
      executable = Path.join(directory, "hypervisor")

      File.write!(
        executable,
        "#!/usr/bin/env sh\nprintf '%s\\n' \"$@\" > '#{marker}'\nexec cat '#{gate}'\n"
      )

      File.chmod!(executable, 0o700)

      image = %Garden.Image{
        directory: directory,
        kernel: "/kernel",
        initrd: "/initrd",
        root: "/root",
        cmdline: "",
        contract: 2
      }

      parent = self()
      reader = fifo_reader(marker)

      {caller, monitor} =
        spawn_monitor(fn ->
          result =
            Garden.VM.CLI.run(image, %VMManager.Command{path: "/bin/work"},
              manager: manager,
              hypervisor: executable,
              scratch_bytes: 16 * 1024 * 1024,
              runtime_directory: Path.join(directory, "runtime")
            )

          send(parent, {:cli_result, result})
        end)

      arguments = reader |> fifo_output() |> String.split("\n", trim: true)

      api =
        arguments
        |> Enum.at(Enum.find_index(arguments, &(&1 == "--api-socket")) + 1)
        |> String.replace_prefix("path=", "")

      guest = Path.join(Path.dirname(api), "vsock.sock")
      {:ok, native} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, api}])

      {:ok, bridge} =
        :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, guest}])

      {peer, peer_monitor} = spawn_monitor(fn -> serve_native(native, gate, "Running") end)

      on_exit(fn ->
        if Process.alive?(caller), do: Process.exit(caller, :kill)

        cleanup(fn ->
          {:ok, definitions} = VMManager.list(manager)

          Enum.each(
            Enum.filter(
              definitions,
              &(&1.config.runtime_directory == Path.join(directory, "runtime"))
            ),
            fn status ->
              cleanup_vm(status.id, manager)
            end
          )
        end)

        :gen_tcp.close(native)
        :gen_tcp.close(bridge)
        if Process.alive?(peer), do: Process.exit(peer, :kill)
      end)

      {:ok, socket} = :gen_tcp.accept(bridge, 5_000)
      assert {:ok, "CONNECT 5000\n"} = :gen_tcp.recv(socket, 0, 5_000)
      :ok = :gen_tcp.send(socket, "OK 5000\n")
      :ok = :inet.setopts(socket, packet: :raw)
      send_frame(socket, %{"type" => "ready", "version" => 2, "contract" => 2})
      assert %{"type" => "execute", "path" => "/bin/work"} = receive_frame(socket)
      {:ok, definitions} = VMManager.list(manager)

      status =
        Enum.find(definitions, &(&1.config.runtime_directory == Path.join(directory, "runtime")))

      assert status.running
      execution = Process.monitor(status.execution)
      finish_command(outcome, socket, caller, monitor)
      assert_receive {:DOWN, ^execution, :process, _, _}, 5_000
      assert_removed(outcome, status.id, manager)
      refute File.exists?(status.directory)
      refute File.exists?(Path.dirname(api))
      :gen_tcp.close(socket)
      :gen_tcp.close(native)
      assert_receive {:DOWN, ^peer_monitor, :process, ^peer, :normal}, 5_000
    end
  end

  defp assert_removed(:caller_down, id, manager) do
    await_removed(id, manager, System.monotonic_time(:millisecond) + 5_000)
  end

  defp assert_removed(code, id, manager) when is_integer(code) do
    assert {:error, :not_found} = VMManager.status(id, manager)
  end

  defp await_removed(id, manager, deadline) do
    case VMManager.status(id, manager) do
      {:error, :not_found} ->
        :ok

      {:ok, _status} ->
        assert System.monotonic_time(:millisecond) < deadline
        :erlang.yield()
        await_removed(id, manager, deadline)
    end
  end

  setup %{tmp_dir: directory} do
    token = System.unique_integer([:positive])
    manager = String.to_atom("vm_cli_manager_#{token}")
    runtime = String.to_atom("vm_cli_runtime_#{token}")

    {:ok, supervisor} =
      VMManager.Supervisor.start_link(
        manager_name: manager,
        runtime_supervisor: runtime,
        state_directory: Path.join(directory, "state")
      )

    Process.unlink(supervisor)
    on_exit(fn -> cleanup(fn -> Supervisor.stop(supervisor, :normal, 5_000) end) end)
    {:ok, manager: manager}
  end

  defp cleanup_vm(id, manager) do
    case VMManager.stop(id, manager) do
      :ok -> assert VMManager.remove(id, manager) in [:ok, {:error, :not_found}]
      {:error, :not_found} -> :ok
      other -> flunk("VM fixture cleanup failed: #{inspect(other)}")
    end
  end

  defp finish_command(:caller_down, socket, caller, monitor) do
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}
    drain_cancel(socket)
  end

  defp finish_command(code, socket, caller, monitor) when is_integer(code) do
    send_frame(socket, %{"type" => "exited", "version" => 2, "code" => code, "signal" => nil})
    assert_receive {:cli_result, {:ok, %VMManager.Result{code: ^code}}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}
  end

  defp drain_cancel(socket) do
    case :gen_tcp.recv(socket, 5, 5_000) do
      {:ok, <<1, length::unsigned-big-32>>} ->
        assert {:ok, payload} = :gen_tcp.recv(socket, length, 5_000)
        assert %{"type" => "cancel"} = Jason.decode!(payload)

        metadata =
          Jason.encode!(%{"type" => "exited", "version" => 2, "code" => 137, "signal" => nil})

        case :gen_tcp.send(socket, <<1, byte_size(metadata)::unsigned-big-32, metadata::binary>>) do
          :ok -> drain_cancel(socket)
          {:error, :closed} -> :ok
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp fifo_reader(path) do
    {:ok, runner, os_pid} = Rexec.run_link([System.find_executable("cat"), path], owner: self())
    Process.unlink(runner)
    {runner, Process.monitor(runner), os_pid}
  end

  defp fifo_output(reader, bytes \\ "")

  defp fifo_output({runner, monitor, os_pid} = reader, bytes) do
    receive do
      {:stdout, ^os_pid, more} ->
        fifo_output(reader, bytes <> more)

      {:DOWN, ^monitor, :process, ^runner, :normal} ->
        bytes

      {:DOWN, ^monitor, :process, ^runner, reason} ->
        flunk("FIFO reader failed: #{inspect(reason)}")
    after
      5_000 -> flunk("FIFO reader did not finish")
    end
  end

  defp cleanup(operation) do
    operation |> Task.async() |> Task.await(5_000)
  end

  defp send_frame(socket, metadata) do
    payload = Jason.encode!(metadata)
    :ok = :gen_tcp.send(socket, <<1, byte_size(payload)::unsigned-big-32, payload::binary>>)
  end

  defp receive_frame(socket) do
    assert {:ok, <<1, length::unsigned-big-32>>} = :gen_tcp.recv(socket, 5, 5_000)
    assert {:ok, payload} = :gen_tcp.recv(socket, length, 5_000)
    Jason.decode!(payload)
  end

  defp serve_native(listener, gate, state) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} ->
        {request, _body} = receive_request(socket, "")
        [_, endpoint | _] = String.split(request)

        {body, next_state} =
          case endpoint do
            "/api/v1/vmm.ping" ->
              {Jason.encode!(%{
                 "version" => "fixture",
                 "build_version" => "fixture",
                 "pid" => 1,
                 "features" => []
               }), state}

            "/api/v1/vm.info" ->
              {Jason.encode!(%{"config" => %{}, "state" => state, "memory_actual_size" => 0}),
               state}

            "/api/v1/vm.shutdown" ->
              {"", "Shutdown"}

            "/api/v1/vmm.shutdown" ->
              {"", :exited}
          end

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)

        if next_state == :exited do
          {:ok, writer, _os_pid} =
            Rexec.run_link(
              [System.find_executable("sh"), "-c", "printf release > \"$1\"", "sh", gate],
              owner: self()
            )

          Process.unlink(writer)
          monitor = Process.monitor(writer)
          assert_receive {:DOWN, ^monitor, :process, ^writer, :normal}, 5_000
        else
          serve_native(listener, gate, next_state)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        {headers, body}

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        receive_request(socket, bytes <> more)
    end
  end
end
