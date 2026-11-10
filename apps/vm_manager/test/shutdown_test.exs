defmodule VMManager.ShutdownTest do
  use ExUnit.Case, async: true
  alias VMManager.{Config, Manager, Status, Store}

  @moduletag :tmp_dir

  test "ordinary agentless stop requests guest shutdown and explicit stopped intent beats restart",
       context do
    context = runtime(context, :clean)
    assert :ok = VMManager.stop(context.id, context.manager)
    assert_receive {:mutation, "vm.power-button"}
    refute_receive {:mutation, "vm.shutdown"}

    assert {:ok, %Status{desired: :stopped, phase: :stopped, cleanup: :ok}} =
             VMManager.status(context.id, context.manager)

    assert :ok = VMManager.stop(context.id, context.manager)
    assert DynamicSupervisor.count_children(context.supervisor).active == 0
    assert File.read!(context.marker) == "caller-owned"
    assert File.exists?(context.control)
  end

  test "ignored guest power button reaches bounded authorized force fallback", context do
    context = runtime(context, :ignore)
    started = System.monotonic_time(:millisecond)
    assert :ok = VMManager.stop(context.id, context.manager, guest_shutdown_timeout_ms: 100)
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 100
    assert elapsed < 2_000
    assert_receive {:mutation, "vm.power-button"}
    assert_receive {:mutation, "vm.shutdown"}
    assert File.read!(context.marker) == "caller-owned"
    assert Process.alive?(context.peer)
  end

  test "explicit force bypasses the guest request and grace interval", context do
    context = runtime(context, :ignore)

    assert :ok =
             VMManager.stop(context.id, context.manager,
               mode: :force,
               guest_shutdown_timeout_ms: 60_000
             )

    assert_receive {:mutation, "vm.shutdown"}
    refute_receive {:mutation, "vm.power-button"}
    assert Process.alive?(context.peer)
  end

  test "concurrent repeated graceful stops share work and force interrupts their wait", context do
    context = runtime(context, :ignore)

    first =
      Task.async(fn ->
        VMManager.stop(context.id, context.manager, guest_shutdown_timeout_ms: 60_000)
      end)

    assert_receive {:mutation, "vm.power-button"}, 2_000
    second = Task.async(fn -> VMManager.stop(context.id, context.manager) end)
    force = Task.async(fn -> VMManager.stop(context.id, context.manager, mode: :force) end)
    assert :ok = Task.await(force, 2_000)
    assert :ok = Task.await(first, 2_000)
    assert :ok = Task.await(second, 2_000)
    assert_receive {:mutation, "vm.shutdown"}
    refute_receive {:mutation, "vm.power-button"}
    refute_receive {:mutation, "vm.shutdown"}
  end

  test "power-button rejection falls back without claiming an unobserved clean guest shutdown",
       context do
    context = runtime(context, :reject)
    assert :ok = VMManager.stop(context.id, context.manager)
    assert_receive {:mutation, "vm.power-button"}
    assert_receive {:mutation, "vm.shutdown"}
    assert {:ok, %Status{cleanup: :ok}} = VMManager.status(context.id, context.manager)
  end

  test "a guest exiting during force request is certified from matching stopped state", context do
    context = runtime(context, :exit_during_force)
    assert :ok = VMManager.stop(context.id, context.manager, mode: :force)
    assert {:ok, %Status{cleanup: :ok}} = VMManager.status(context.id, context.manager)
  end

  test "guest deadline does not shorten the independent force request budget", context do
    context = runtime(context, :slow_force)
    assert :ok = VMManager.stop(context.id, context.manager, guest_shutdown_timeout_ms: 100)
    assert_receive {:mutation, "vm.shutdown"}
  end

  for scenario <- [:identity_change, :endpoint_loss, :shutdown_failure] do
    test "#{scenario} retains custody without touching caller resources", context do
      context = runtime(context, unquote(scenario))

      assert {:error, {:cleanup_incomplete, _}} =
               VMManager.stop(context.id, context.manager, guest_shutdown_timeout_ms: 0)

      assert {:ok, %Status{phase: :retained}} = VMManager.status(context.id, context.manager)
      assert {:ok, definitions} = Store.load(context.state_directory)
      assert definitions[context.id].reserved
      assert File.read!(context.marker) == "caller-owned"
      if unquote(scenario) != :endpoint_loss, do: assert(File.exists?(context.control))
      if unquote(scenario) == :identity_change, do: refute_receive({:mutation, "vm.shutdown"})

      assert {:ok, "waiting"} =
               VMManager.define(%Config{id: "waiting", kernel: "/kernel"}, context.manager)

      assert {:error, {:capacity_exhausted, :vms}} = VMManager.start("waiting", context.manager)
    end
  end

  test "invalid policies do not change durable running intent", context do
    context = runtime(context, :ignore)

    assert {:error, :invalid_stop_policy} =
             VMManager.stop(context.id, context.manager, mode: :unknown)

    assert {:error, :invalid_stop_policy} =
             VMManager.stop(context.id, context.manager, guest_shutdown_timeout_ms: -1)

    assert {:ok, %Status{desired: :running, running: true}} =
             VMManager.status(context.id, context.manager)

    assert :ok = VMManager.stop(context.id, context.manager, mode: :force)
  end

  defp runtime(context, scenario) do
    directory = context.tmp_dir
    control = Path.join(System.tmp_dir!(), "shutdown-#{System.unique_integer([:positive])}.sock")
    marker = Path.join(directory, "caller-data")
    File.write!(marker, "caller-owned")

    {:ok, listener} =
      :gen_tcp.listen(
        0,
        [:binary, active: false, packet: :line, ifaddr: {:local, control}]
      )

    parent = self()

    config = %Config{
      id: "shutdown",
      kernel: "/kernel",
      mode: :attach,
      control_endpoint: control,
      restart: :always
    }

    native = %{
      "payload" => %{"kernel" => "/kernel", "cmdline" => " sower.vm.id=shutdown"},
      "cpus" => %{"boot_vcpus" => 1, "max_vcpus" => 1},
      "memory" => %{"size" => config.memory},
      "disks" => [],
      "net" => []
    }

    peer = spawn_link(fn -> serve(listener, parent, scenario, native, "Running") end)

    on_exit(fn ->
      Process.unlink(peer)
      Process.exit(peer, :kill)
      :gen_tcp.close(listener)
      File.rm(control)
    end)

    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    state_directory = Path.join(directory, "state")

    manager =
      start_supervised!(
        {Manager, state_directory: state_directory, runtime_supervisor: supervisor}
      )

    assert {:ok, id} = VMManager.define(config, manager)
    assert :ok = VMManager.start(id, manager)
    assert {:ok, %Status{running: true}} = VMManager.await_running(id, manager)

    %{
      id: id,
      manager: manager,
      supervisor: supervisor,
      peer: peer,
      marker: marker,
      control: control,
      state_directory: state_directory
    }
  end

  defp serve(listener, parent, scenario, native, state) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, line} = :gen_tcp.recv(socket, 0, 5_000)
        headers(socket)
        [method, path | _] = String.split(line)
        endpoint = String.replace_prefix(path, "/api/v1/", "")
        if method == "PUT", do: send(parent, {:mutation, endpoint})
        {status, body, native, state} = response(endpoint, scenario, native, state)

        if scenario == :endpoint_loss and endpoint == "vm.power-button" do
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        else
          if scenario == :slow_force and endpoint == "vm.shutdown", do: Process.sleep(50)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 #{status} OK\r\ncontent-length: ",
              to_string(byte_size(body)),
              "\r\nconnection: close\r\n\r\n",
              body
            ])

          :gen_tcp.close(socket)
          serve(listener, parent, scenario, native, state)
        end

      {:error, :closed} ->
        :ok
    end
  end

  defp response("vm.info", _scenario, native, state) do
    {200,
     Jason.encode!(%{
       "state" => state,
       "device_tree" => nil,
       "config" => native,
       "memory_actual_size" => 536_870_912
     }), native, state}
  end

  defp response("vm.power-button", :clean, native, _state), do: {204, "", native, "Created"}
  defp response("vm.power-button", :reject, native, state), do: {500, "rejected", native, state}

  defp response("vm.power-button", :identity_change, native, state) do
    native = put_in(native["payload"]["cmdline"], " sower.vm.id=unrelated")
    {204, "", native, state}
  end

  defp response("vm.power-button", _scenario, native, state), do: {204, "", native, state}

  defp response("vm.shutdown", :shutdown_failure, native, state),
    do: {500, "failed", native, state}

  defp response("vm.shutdown", :exit_during_force, native, _state),
    do: {500, "already stopped", native, "Created"}

  defp response("vm.shutdown", _scenario, native, _state), do: {204, "", native, "Created"}

  defp headers(socket) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, "\r\n"} -> :ok
      {:ok, _} -> headers(socket)
    end
  end
end
