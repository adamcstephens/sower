defmodule CloudHypervisor.APITest do
  use ExUnit.Case, async: true

  alias CloudHypervisor.{API, Config}
  alias CloudHypervisor.API.{Error, Info, Ping}

  test "decodes typed reads from independently addressed sockets" do
    ping = %{
      "version" => "53.0.0",
      "build_version" => "build",
      "pid" => 42,
      "features" => ["kvm"]
    }

    info = %{
      "config" => %{"cpus" => %{"boot_vcpus" => 1}},
      "state" => "Running",
      "memory_actual_size" => 123
    }

    {client, task} = server(200, Jason.encode!(ping))
    {other, other_task} = server(200, Jason.encode!(info))

    assert {:ok, %Ping{version: "53.0.0", pid: 42, features: ["kvm"]}} = API.ping(client)

    assert {:ok, %Info{state: "Running", memory_actual_size: 123, config: info_config}} =
             API.info(other)

    assert info_config == info["config"]
    assert {"GET /api/v1/vmm.ping HTTP/1.1", ""} = Task.await(task)
    assert {"GET /api/v1/vm.info HTTP/1.1", ""} = Task.await(other_task)
  end

  test "shared create configuration encodes byte memory and direct boot over HTTP" do
    config = %Config{kernel: "/kernel", memory: 134_221_824}
    {client, task} = server(204, "")
    assert :ok = API.create(client, config)
    assert {"PUT /api/v1/vm.create HTTP/1.1", body} = Task.await(task)

    assert Jason.decode!(body) == %{
             "payload" => %{"kernel" => "/kernel"},
             "memory" => %{"size" => 134_221_824}
           }
  end

  test "empty 200/204 mutation successes" do
    for {function, endpoint} <- [
          boot: "vm.boot",
          shutdown: "vm.shutdown",
          delete: "vm.delete",
          shutdown_vmm: "vmm.shutdown"
        ],
        status <- [200, 204] do
      {client, task} = server(status, "")
      assert :ok = apply(API, function, [client])
      assert {"PUT /api/v1/" <> path, ""} = Task.await(task)
      assert path == endpoint <> " HTTP/1.1"
    end
  end

  test "preserves all non-success HTTP statuses and arbitrary error bodies without retrying" do
    for {status, body, expected} <- [
          {404, "[\"VM not created\"]", ["VM not created"]},
          {400, "{\"error\":\"invalid config\"}", %{"error" => "invalid config"}},
          {500, "backend failed", "backend failed"},
          {409, "\"already running\"", "already running"},
          {302, "", ""}
        ] do
      {client, task} = server(status, body)
      assert {:error, %Error{kind: :http, status: ^status, body: ^expected}} = API.boot(client)
      Task.await(task)
    end
  end

  test "distinguishes unavailable sockets and bounded request timeout from HTTP failures" do
    client = %API{socket: socket_path(), timeout: 50}

    assert {:error, %Error{kind: :transport, status: nil, reason: %Req.TransportError{}}} =
             API.info(client)

    {client, task} = server(200, "", 200)

    assert {:error,
            %Error{kind: :transport, status: nil, reason: %Req.TransportError{reason: :timeout}}} =
             API.boot(%{client | timeout: 50})

    Task.await(task)
  end

  test "pool checkout exhaustion returns a typed transport error without raising" do
    socket = socket_path()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, socket}, backlog: 50])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm!(socket)
    end)

    supervisor = start_supervised!(Task.Supervisor)
    owner = self()
    client = %API{socket: socket, timeout: 50}

    try do
      server =
        Task.Supervisor.async_nolink(supervisor, fn ->
          connections =
            for index <- 1..50 do
              {:ok, connection} = :gen_tcp.accept(listener, 5_000)
              {headers, ""} = receive_request(connection, "")
              assert hd(String.split(headers, "\r\n")) == "GET /api/v1/vmm.ping HTTP/1.1"
              send(owner, {:held_request, self(), index})
              connection
            end

          receive do
            :release ->
              body =
                Jason.encode!(%{
                  version: "53.0.0",
                  build_version: "build",
                  pid: 42,
                  features: []
                })

              for connection <- connections do
                :ok =
                  :gen_tcp.send(
                    connection,
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
                  )

                :ok = :gen_tcp.close(connection)
              end
          end
        end)

      server_pid = server.pid

      requests =
        for index <- 1..50 do
          task =
            Task.Supervisor.async_nolink(supervisor, fn ->
              Req.request(
                url: "http://localhost/api/v1/vmm.ping",
                unix_socket: socket,
                finch: [
                  conn_opts: [transport_opts: [timeout: client.timeout]],
                  pool_timeout: 5_000,
                  receive_timeout: 30_000,
                  request_timeout: 30_000
                ],
                retry: false,
                redirect: false,
                decode_body: false
              )
            end)

          assert_receive {:held_request, ^server_pid, ^index}, 5_000
          task
        end

      started = System.monotonic_time(:millisecond)

      assert {:error,
              %Error{kind: :transport, status: nil, reason: {:pool_timeout, %RuntimeError{}}}} =
               API.ping(client)

      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed < 1_000

      send(server_pid, :release)

      for task <- requests do
        assert {:ok, %Req.Response{status: 200}} = Task.await(task, 5_000)
      end

      Task.await(server, 5_000)
    after
      stop_supervised!(Task.Supervisor)
      :gen_tcp.close(listener)
    end
  end

  test "malformed successful read responses are decode failures" do
    for body <- ["", "not JSON", "[]", "{}", "{\"version\":12}"] do
      {client, task} = server(200, body)
      assert {:error, %Error{kind: :decode, status: 200}} = API.ping(client)
      Task.await(task)
    end
  end

  defp socket_path do
    Path.join(System.tmp_dir!(), "ch-api-#{System.unique_integer([:positive])}.sock")
  end

  defp server(status, body, delay \\ 0) do
    socket = socket_path()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ifaddr: {:local, socket}])

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm!(socket)
    end)

    task =
      Task.async(fn ->
        {:ok, connection} = :gen_tcp.accept(listener, 1000)
        {headers, request_body} = receive_request(connection, "")
        Process.sleep(delay)

        :gen_tcp.send(
          connection,
          "HTTP/1.1 #{status} Response\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
        )

        :gen_tcp.close(connection)
        {hd(String.split(headers, "\r\n")), request_body}
      end)

    {%API{socket: socket}, task}
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
          {:ok, more} = :gen_tcp.recv(socket, 0, 1000)
          receive_request(socket, bytes <> more)
        end

      [_] ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 1000)
        receive_request(socket, bytes <> more)
    end
  end
end
