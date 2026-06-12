defmodule Garden.ActivatorClientTest do
  use ExUnit.Case, async: true

  alias Garden.ActivatorClient
  alias Garden.ActivatorClient.{Request, Response}

  describe "Request struct" do
    test "creates request with required gardens" do
      request = %Request{id: "abc123", type: "nixos", path: "/nix/store/xyz"}
      assert request.id == "abc123"
      assert request.type == "nixos"
      assert request.path == "/nix/store/xyz"
      assert request.mode == nil
    end

    test "creates request with optional mode" do
      request = %Request{id: "abc123", type: "nixos", path: "/nix/store/xyz", mode: "switch"}
      assert request.mode == "switch"
    end
  end

  describe "Response struct" do
    test "creates response with required gardens" do
      response = %Response{id: "abc123", type: "output"}
      assert response.id == "abc123"
      assert response.type == "output"
      assert response.data == nil
      assert response.exit_code == nil
    end

    test "creates response with optional gardens" do
      response = %Response{id: "abc123", type: "complete", data: "done", exit_code: 0}
      assert response.data == "done"
      assert response.exit_code == 0
    end
  end

  describe "socket_available?/1" do
    test "returns false for non-existent socket" do
      refute ActivatorClient.socket_available?("/nonexistent/socket.sock")
    end

    test "returns true for existing file" do
      tmp_path = Path.join(System.tmp_dir!(), "test-socket-#{:rand.uniform(100_000)}")
      File.write!(tmp_path, "")

      on_exit(fn -> File.rm(tmp_path) end)

      assert ActivatorClient.socket_available?(tmp_path)
    end
  end

  describe "activate/3" do
    test "returns error when socket does not exist" do
      result =
        ActivatorClient.activate("nixos", "/nix/store/xyz",
          socket_path: "/nonexistent/socket.sock"
        )

      assert result == {:error, :socket_not_found}
    end

    test "returns error when connection refused" do
      tmp_dir = Path.join(System.tmp_dir!(), "activator-test-#{:rand.uniform(100_000)}")
      socket_path = Path.join(tmp_dir, "activator.sock")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      File.touch!(socket_path)

      result = ActivatorClient.activate("nixos", "/nix/store/xyz", socket_path: socket_path)

      assert result == {:error, :connection_refused}
    end

    test "successful activation with streaming output" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "nixos"
          assert request["path"] == "/nix/store/xyz"
          assert request["mode"] == "switch"

          send_response(client_socket, %{id: request["id"], type: "output", data: "line 1"})
          send_response(client_socket, %{id: request["id"], type: "output", data: "line 2"})
          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      {:ok, output_agent} = Agent.start_link(fn -> [] end)

      on_output = fn line ->
        Agent.update(output_agent, fn lines -> [line | lines] end)
      end

      result =
        ActivatorClient.activate("nixos", "/nix/store/xyz",
          socket_path: socket_path,
          mode: "switch",
          on_output: on_output
        )

      assert {:ok, ["line 1", "line 2"]} = result

      streamed_lines = Agent.get(output_agent, fn lines -> Enum.reverse(lines) end)
      assert streamed_lines == ["line 1", "line 2"]
    end

    test "handles activation failure with exit code" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)

          send_response(client_socket, %{id: request["id"], type: "output", data: "starting..."})

          send_response(client_socket, %{
            id: request["id"],
            type: "error",
            data: "activation failed"
          })

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 1})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      result =
        ActivatorClient.activate("home-manager", "/nix/store/xyz", socket_path: socket_path)

      assert {:error, {:activation_failed, 1, ["starting...", "activation failed"]}} = result
    end

    test "handles home-manager activation without mode" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "home-manager"
          refute Map.has_key?(request, "mode")

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      result =
        ActivatorClient.activate("home-manager", "/nix/store/xyz", socket_path: socket_path)

      assert {:ok, []} = result
    end
  end

  # Helper functions for mock server

  defp start_mock_server(handler) do
    tmp_dir = Path.join(System.tmp_dir!(), "activator-test-#{:rand.uniform(100_000)}")
    socket_path = Path.join(tmp_dir, "activator.sock")
    File.mkdir_p!(tmp_dir)

    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, listen_socket} =
          :gen_tcp.listen(0, [
            {:ifaddr, {:local, socket_path}},
            :binary,
            {:active, false},
            {:packet, :line},
            {:reuseaddr, true}
          ])

        send(parent, {:ready, socket_path})
        accept_loop(listen_socket, handler)
      end)

    receive do
      {:ready, path} -> {path, pid}
    after
      5000 -> raise "Mock server failed to start"
    end
  end

  defp accept_loop(listen_socket, handler) do
    case :gen_tcp.accept(listen_socket, 5000) do
      {:ok, client_socket} ->
        case :gen_tcp.recv(client_socket, 0, 5000) do
          {:ok, request_line} ->
            handler.(String.trim_trailing(request_line, "\n"), client_socket)
            :gen_tcp.close(client_socket)

          {:error, _reason} ->
            :gen_tcp.close(client_socket)
        end

        accept_loop(listen_socket, handler)

      {:error, :timeout} ->
        accept_loop(listen_socket, handler)

      {:error, _reason} ->
        :gen_tcp.close(listen_socket)
    end
  end

  defp stop_mock_server(pid) do
    if Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end
  end

  defp send_response(socket, response) do
    line = Jason.encode!(response) <> "\n"
    :gen_tcp.send(socket, line)
  end
end
