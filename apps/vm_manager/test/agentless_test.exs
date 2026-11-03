defmodule VMManager.AgentlessTest do
  use ExUnit.Case, async: true

  test "agentless attachment reaches Running without opening a guest session and remains alive until stop" do
    directory = Path.join(System.tmp_dir!(), "agentless-#{System.unique_integer([:positive])}")
    File.mkdir!(directory)
    control = Path.join(directory, "control.sock")
    guest = Path.join(directory, "guest.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, control}])

    {:ok, bridge} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ifaddr: {:local, guest}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      :gen_tcp.close(bridge)
      File.rm_rf!(directory)
    end)

    config = %VMManager.Config{
      id: "agentless",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: control
    }

    native = %{
      "payload" => %{"kernel" => "/kernel", "cmdline" => " sower.vm.id=agentless"},
      "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
      "memory" => %{"size" => 536_870_912},
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

    server =
      Task.async(fn ->
        for {method, endpoint, body} <- [
              {"GET", "vm.info", info.("Running")},
              {"GET", "vm.info", info.("Running")},
              {"PUT", "vm.shutdown", ""},
              {"GET", "vm.info", info.("Created")}
            ] do
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)

          assert {:ok, "#{method} /api/v1/#{endpoint} HTTP/1.1\r\n"} ==
                   :gen_tcp.recv(socket, 0, 5_000)

          headers(socket)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-length: ",
              to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

          :gen_tcp.close(socket)
        end
      end)

    {:ok, execution} = VMManager.Execution.start_link(VMManager.Config.to_options(config))
    on_exit(fn -> if Process.alive?(execution), do: GenServer.stop(execution) end)

    assert {:ok, %VMManager.Status{running: true, phase: :running, persistent: true}} =
             GenServer.call(execution, :await_running, 5_000)

    assert {:error, :guest_agent_disabled} = GenServer.call(execution, :await_ready)

    assert {:error, :guest_agent_disabled} =
             GenServer.call(
               execution,
               {:execute, %VMManager.Command{path: "/bin/true"}, []}
             )

    assert {:error, :timeout} = :gen_tcp.accept(bridge, 100)
    assert Process.alive?(execution)
    assert :ok = GenServer.call(execution, :stop, 5_000)

    assert %VMManager.Status{phase: :stopped, running: false, cleanup: :ok} =
             GenServer.call(execution, :status)

    Task.await(server)
  end

  test "disabled guest operations take precedence for stopped definitions" do
    directory =
      Path.join(System.tmp_dir!(), "agentless-definition-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, manager} = VMManager.Manager.start_link(state_directory: directory)
    config = %VMManager.Config{id: "stopped-agentless", kernel: "/kernel"}
    assert {:ok, id} = VMManager.define(config, manager)
    assert {:error, :guest_agent_disabled} = VMManager.await_ready(id, manager)

    assert {:error, :guest_agent_disabled} =
             VMManager.execute(id, %VMManager.Command{path: "/bin/true"}, [], manager)

    assert {:error, :vm_unavailable} = VMManager.await_running(id, manager)
    GenServer.stop(manager)
  end

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> headers(socket)
    end
  end
end
