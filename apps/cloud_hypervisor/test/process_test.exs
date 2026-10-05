defmodule CloudHypervisor.ProcessTest do
  use ExUnit.Case, async: true

  alias CloudHypervisor.{API, Config, Launch}
  alias CloudHypervisor.Process, as: VMM

  @timeout 5_000

  test "keeps real exit status and separate stdout and stderr after early exit" do
    executable = executable("printf 'native stdout\\n'; printf 'native stderr\\n' >&2; exit 23")
    {:ok, pid} = start(executable)

    assert {:error, {:exited, {:exit_status, 23}}} = VMM.await_ready(pid)
    assert output(pid, :stdout) == "native stdout\n"
    assert output(pid, :stderr) == "native stderr\n"
    assert_receive {:cloud_hypervisor, ^pid, {:exited, {:exit_status, 23}}}, @timeout
    assert %VMM.Status{phase: :exited, outcome: {:exit_status, 23}} = VMM.status(pid)
    refute File.exists?(VMM.status(pid).directory)
    assert {:ok, {:exit_status, 23}} = VMM.stop(pid, :force)
  end

  test "normal completion preserves exit status zero without claiming readiness" do
    {:ok, pid} = start(executable("exit 0"))
    assert {:error, {:exited, {:exit_status, 0}}} = VMM.await_ready(pid)
    assert_receive {:cloud_hypervisor, ^pid, {:exited, {:exit_status, 0}}}, @timeout
    assert %VMM.Status{phase: :exited, outcome: {:exit_status, 0}} = VMM.status(pid)
    assert {:ok, {:exit_status, 0}} = VMM.stop(pid, :force)
    refute File.exists?(VMM.status(pid).directory)
  end

  test "reaps descendants holding output open when the direct child exits" do
    executable = executable("sleep 60 &\nprintf 'descendant=%s\\n' \"$!\"\nexit 7")
    {:ok, pid} = start(executable)
    assert {:error, {:exited, {:exit_status, 7}}} = VMM.await_ready(pid)
    descendant = output(pid, :stdout) |> String.trim() |> String.replace_prefix("descendant=", "")
    refute File.exists?("/proc/#{descendant}")
    assert_receive {:cloud_hypervisor, ^pid, {:exited, {:exit_status, 7}}}, @timeout
  end

  test "force stop reports the direct child's signal and removes only its private directory" do
    executable = executable("printf 'running\\n'; exec sleep 60")
    {:ok, pid} = start(executable)
    assert output(pid, :stdout) == "running\n"
    directory = VMM.status(pid).directory
    assert {:ok, {:signal, 9}} = VMM.stop(pid, :force)
    assert_receive {:cloud_hypervisor, ^pid, {:exited, {:signal, 9}}}, @timeout
    refute File.exists?(directory)
    assert {:error, {:stopped, :force}} = VMM.await_ready(pid)
  end

  test "graceful stop escalates a signal-ignoring child and its escaped descendants" do
    executable =
      executable(
        "trap '' TERM; setsid sh -c 'trap \"\" TERM; printf \"descendant=%s\\n\" \"$$\"; exec sleep 60' &\nwait"
      )

    {:ok, pid} = start(executable)
    descendant = output(pid, :stdout) |> String.trim() |> String.replace_prefix("descendant=", "")

    [_state, _parent, group, session | _] =
      File.read!("/proc/#{descendant}/stat")
      |> String.split(") ", parts: 2)
      |> List.last()
      |> String.split()

    assert group == descendant
    assert session == descendant
    assert {:ok, {:signal, 9}} = VMM.stop(pid, :graceful)
    refute File.exists?("/proc/#{descendant}")
  end

  test "readiness timeout kills and reaps the child before replying" do
    executable = executable("printf 'running\\n'; exec sleep 60")
    {:ok, pid} = start(executable, readiness_timeout: 150)
    assert output(pid, :stdout) == "running\n"
    assert {:error, :readiness_timeout} = VMM.await_ready(pid)
    status = VMM.status(pid)
    assert status.phase == :failed
    assert status.outcome == {:signal, 9}
    refute File.exists?("/proc/#{status.os_pid}")
    refute File.exists?(status.directory)
  end

  test "an explicit owner dying under a supervisor kills the whole native tree" do
    executable = executable("sleep 60 &\nprintf 'descendant=%s\\n' \"$!\"\nwait")

    owner =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)

    {:ok, pid} =
      start_supervised(
        {VMM, launch: %Launch{executable: executable}, config: config(), owner: owner}
      )

    directory = VMM.status(pid).directory
    os_pid = wait_for_pid(pid)
    descendant = wait_for_child(os_pid)
    monitor = Process.monitor(pid)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
    refute File.exists?("/proc/#{os_pid}")
    refute File.exists?("/proc/#{descendant}")
    refute File.exists?(directory)
  end

  test "GenServer shutdown waits for escaped descendants before removing owned sockets" do
    executable =
      executable("setsid sh -c 'printf \"descendant=%s\\n\" \"$$\"; exec sleep 60' &\nwait")

    {:ok, pid} = start(executable)
    descendant = output(pid, :stdout) |> String.trim() |> String.replace_prefix("descendant=", "")
    status = VMM.status(pid)

    assert :ok = GenServer.stop(pid, :normal, 7_000)
    refute File.exists?("/proc/#{status.os_pid}")
    refute File.exists?("/proc/#{descendant}")
    refute File.exists?(status.directory)
  end

  @tag timeout: 15_000
  test "unconfirmed cleanup retains owned sockets and reports failure on server shutdown" do
    {:ok, pid} = start(executable("exec sleep 60"), readiness_timeout: 15_000)
    {:ok, client} = VMM.client(pid)
    status = VMM.status(pid)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, client.socket}])

    [_state, runner | _] =
      File.read!("/proc/#{status.os_pid}/stat")
      |> String.split(") ", parts: 2)
      |> List.last()
      |> String.split()

    on_exit(fn ->
      System.cmd("kill", ["-CONT", runner], stderr_to_stdout: true)
      :gen_tcp.close(listener)
      wait_for_absence(status.os_pid)
      File.rm_rf(status.directory)
    end)

    assert {_, 0} = System.cmd("kill", ["-STOP", runner], stderr_to_stdout: true)
    monitor = Process.monitor(pid)

    stop_result =
      try do
        GenServer.stop(pid, :normal, 7_000)
      catch
        :exit, reason -> {:error, reason}
      end

    assert {:error, _reason} = stop_result

    assert_receive {:DOWN, ^monitor, :process, ^pid, {:shutdown, {:cleanup_failed, message}}},
                   @timeout

    assert_receive {:cloud_hypervisor, ^pid, {:failed, {:cleanup_failed, ^message}}}, @timeout
    assert File.exists?(status.directory)
    assert File.exists?(client.socket)
    refute_receive {:cloud_hypervisor, ^pid, {:exited, _outcome}}

    assert {_, 0} = System.cmd("kill", ["-CONT", runner], stderr_to_stdout: true)
    wait_for_absence(status.os_pid)
    assert File.exists?(client.socket)
  end

  test "refuses foreign execution sockets without touching their contents" do
    path = Path.join(System.tmp_dir!(), "ch-foreign-#{System.unique_integer([:positive])}.sock")
    File.write!(path, "foreign resource")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:caller_socket, :api_socket}} =
             VMM.start_link(launch: %Launch{api_socket: path}, config: config())

    assert {:error, {:caller_socket, :vsock}} =
             VMM.start_link(
               launch: %Launch{},
               config: %{config() | vsock: %Config.Vsock{cid: 3, socket: path}}
             )

    assert File.read!(path) == "foreign resource"
  end

  test "reports executable spawn failure and cleans up without claiming readiness" do
    {:ok, pid} = start("/nonexistent/cloud-hypervisor-#{System.unique_integer([:positive])}")
    assert {:error, {:startup, message}} = VMM.await_ready(pid)
    assert is_binary(message)

    assert %VMM.Status{phase: :failed, os_pid: nil, outcome: nil, error: {:startup, ^message}} =
             VMM.status(pid)

    assert_receive {:cloud_hypervisor, ^pid, {:failed, {:startup, ^message}}}, @timeout
    assert {:error, {:startup, ^message}} = VMM.stop(pid, :force)
    refute File.exists?(VMM.status(pid).directory)
    refute_receive {:cloud_hypervisor, ^pid, {:ready, _}}
  end

  test "API boot observes VM Running and VM shutdown leaves the VMM alive" do
    executable = executable("printf 'running\\n'; exec sleep 60")
    vm_config = %{config() | vsock: %Config.Vsock{cid: 5, socket: nil}}
    {:ok, pid} = start(executable, mode: :api, config: vm_config)
    {:ok, client} = VMM.client(pid)
    assert {:ok, %File.Stat{mode: mode}} = File.stat(VMM.status(pid).directory)
    assert Bitwise.band(mode, 0o777) == 0o700
    server = api_server(client)

    assert {:ok, %VMM.Status{phase: :ready, mode: :api, api_ready: true, vm_state: "Running"}} =
             VMM.await_ready(pid)

    assert_receive {:cloud_hypervisor, ^pid, {:ready, %VMM.Status{phase: :ready}}}, @timeout
    assert :ok = API.shutdown(client)
    assert {:ok, %API.Info{state: "Shutdown"}} = API.info(client)
    assert File.exists?("/proc/#{VMM.status(pid).os_pid}")
    assert {:ok, {:signal, 9}} = VMM.stop(pid, :graceful)
    refute File.exists?("/proc/#{VMM.status(pid).os_pid}")
    refute File.exists?(VMM.status(pid).directory)
    Task.await(server, @timeout)
  end

  test "an API boot rejection kills and reaps before failed readiness returns" do
    executable = executable("exec sleep 60")
    {:ok, pid} = start(executable, mode: :api)
    {:ok, client} = VMM.client(pid)
    server = api_server(client, 500)

    assert {:error, {:startup, :boot, %API.Error{kind: :http, status: 500}}} =
             VMM.await_ready(pid)

    assert %VMM.Status{phase: :failed, api_ready: true, outcome: {:signal, 9}} = VMM.status(pid)
    refute File.exists?("/proc/#{VMM.status(pid).os_pid}")
    refute File.exists?(VMM.status(pid).directory)
    refute_receive {:cloud_hypervisor, ^pid, {:ready, _}}
    Task.await(server, @timeout)
  end

  test "owner death stays responsive while a readiness HTTP response is stalled" do
    executable = executable("exec sleep 60")

    owner =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    {:ok, pid} = start(executable, owner: owner)
    {:ok, client} = VMM.client(pid)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, client.socket}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, connection} = :gen_tcp.accept(listener, @timeout)
    on_exit(fn -> :gen_tcp.close(connection) end)
    os_pid = wait_for_pid(pid)
    monitor = Process.monitor(pid)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, @timeout
    refute File.exists?("/proc/#{os_pid}")
    refute File.exists?(Path.dirname(client.socket))
  end

  defp start(executable, options \\ []) do
    options =
      Keyword.merge(
        [
          launch: %Launch{executable: executable},
          config: config(),
          owner: self(),
          readiness_timeout: 3_000
        ],
        options
      )

    start_supervised({VMM, options})
  end

  defp config, do: %Config{kernel: "/unused-test-kernel"}

  defp executable(body) do
    path =
      Path.join(System.tmp_dir!(), "ch-process-fixture-#{System.unique_integer([:positive])}")

    File.write!(path, "#!/usr/bin/env sh\n" <> body <> "\n")
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp output(pid, stream, bytes \\ "") do
    receive do
      {:cloud_hypervisor, ^pid, {^stream, data}} ->
        bytes = bytes <> data
        if String.ends_with?(bytes, "\n"), do: bytes, else: output(pid, stream, bytes)
    after
      @timeout -> flunk("missing #{stream} output from #{inspect(pid)}")
    end
  end

  defp wait_for_pid(pid, attempts \\ 100)
  defp wait_for_pid(_pid, 0), do: flunk("missing native pid")

  defp wait_for_pid(pid, attempts) do
    case VMM.status(pid).os_pid do
      nil ->
        Process.sleep(10)
        wait_for_pid(pid, attempts - 1)

      os_pid ->
        os_pid
    end
  end

  defp wait_for_child(pid, attempts \\ 100)
  defp wait_for_child(_pid, 0), do: flunk("missing native descendant")

  defp wait_for_child(pid, attempts) do
    case File.read("/proc/#{pid}/task/#{pid}/children") do
      {:ok, children} when children != "" ->
        children |> String.split() |> hd()

      _ ->
        Process.sleep(10)
        wait_for_child(pid, attempts - 1)
    end
  end

  defp wait_for_absence(pid, attempts \\ 500)
  defp wait_for_absence(pid, 0), do: flunk("native process #{pid} was not reaped")

  defp wait_for_absence(pid, attempts) do
    if File.exists?("/proc/#{pid}") do
      Process.sleep(10)
      wait_for_absence(pid, attempts - 1)
    end
  end

  defp api_server(%API{} = client, boot_status \\ 204) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, client.socket}])

    on_exit(fn -> :gen_tcp.close(listener) end)
    Task.async(fn -> serve_api(listener, "Empty", boot_status) end)
  end

  defp serve_api(listener, vm_state, boot_status) do
    {:ok, socket} = :gen_tcp.accept(listener, @timeout)
    {headers, _request_body} = receive_request(socket, "")
    [_, endpoint | _] = String.split(hd(String.split(headers, "\r\n")), " ")

    {status, body, next_state, done} =
      case {endpoint, vm_state} do
        {"/api/v1/vmm.ping", _} ->
          {200,
           %{"version" => "fixture", "build_version" => "fixture", "pid" => 1, "features" => []},
           vm_state, false}

        {"/api/v1/vm.create", "Empty"} ->
          {204, nil, "Created", false}

        {"/api/v1/vm.boot", "Created"} when boot_status == 204 ->
          {204, nil, "Running", false}

        {"/api/v1/vm.boot", "Created"} ->
          {boot_status, %{"error" => "boot rejected"}, vm_state, true}

        {"/api/v1/vm.info", state} ->
          {200, %{"config" => %{}, "state" => state, "memory_actual_size" => 0}, state, false}

        {"/api/v1/vm.shutdown", "Running"} ->
          {204, nil, "Shutdown", false}

        {"/api/v1/vmm.shutdown", _} ->
          {204, nil, vm_state, true}

        _ ->
          {409, %{"error" => "invalid state transition"}, vm_state, false}
      end

    body = if body == nil, do: "", else: Jason.encode!(body)

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 #{status} Response\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
      )

    :gen_tcp.close(socket)
    if not done, do: serve_api(listener, next_state, boot_status)
  end

  defp receive_request(socket, bytes) do
    case String.split(bytes, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, headers) do
            [_, length] -> String.to_integer(length)
            nil -> 0
          end

        if byte_size(body) >= length do
          {headers, body}
        else
          {:ok, more} = :gen_tcp.recv(socket, 0, @timeout)
          receive_request(socket, bytes <> more)
        end

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, @timeout)
        receive_request(socket, bytes <> more)
    end
  end
end
