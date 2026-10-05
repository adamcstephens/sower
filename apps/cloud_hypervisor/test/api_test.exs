defmodule CloudHypervisor.APITest do
  use ExUnit.Case, async: true

  alias CloudHypervisor.API
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

  test "native create payload and empty 200/204 mutation successes" do
    config = %{"payload" => %{"kernel" => "/kernel"}, "memory" => %{"size" => 134_217_728}}
    {client, task} = server(204, "")
    assert :ok = API.create(client, config)
    assert {"PUT /api/v1/vm.create HTTP/1.1", body} = Task.await(task)
    assert Jason.decode!(body) == config

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
