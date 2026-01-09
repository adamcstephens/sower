defmodule SowerAgent.SeedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SowerAgent.Seed
  alias SowerClient.Seed, as: ClientSeed

  describe "activate/1" do
    test "returns noop when activation is disabled" do
      Application.put_env(:sower_agent, :enable_activation, false)
      on_exit(fn -> Application.put_env(:sower_agent, :enable_activation, true) end)

      seed = %ClientSeed{name: "test", seed_type: "nixos", artifact: "/nix/store/xyz"}
      assert {:ok, ["noop"]} = Seed.activate(seed)
    end

    test "uses socket when available" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "nixos"
          assert request["path"] == "/nix/store/xyz"
          assert request["mode"] == "switch"

          send_response(client_socket, %{id: request["id"], type: "output", data: "activating..."})

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      Application.put_env(:sower_agent, :activator_socket, socket_path)

      on_exit(fn ->
        Application.delete_env(:sower_agent, :activator_socket)
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      seed = %ClientSeed{name: "test", seed_type: "nixos", artifact: "/nix/store/xyz"}
      assert {:ok, ["activating..."]} = Seed.activate(seed)
    end

    test "uses socket for home-manager without mode" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "home-manager"
          assert request["path"] == "/nix/store/hm"
          refute Map.has_key?(request, "mode")

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      Application.put_env(:sower_agent, :activator_socket, socket_path)

      on_exit(fn ->
        Application.delete_env(:sower_agent, :activator_socket)
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      seed = %ClientSeed{name: "test", seed_type: "home-manager", artifact: "/nix/store/hm"}
      assert {:ok, []} = Seed.activate(seed)
    end

    test "logs error on socket activation failure" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)

          send_response(client_socket, %{
            id: request["id"],
            type: "error",
            data: "permission denied"
          })

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 1})
        end)

      Application.put_env(:sower_agent, :activator_socket, socket_path)

      on_exit(fn ->
        Application.delete_env(:sower_agent, :activator_socket)
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      seed = %ClientSeed{name: "test", seed_type: "nixos", artifact: "/nix/store/xyz"}

      log =
        capture_log(fn ->
          assert {:error, 1} = Seed.activate(seed)
        end)

      assert log =~ "Failed to activate via socket"
    end
  end

  describe "run_via_socket/3" do
    test "invokes on_output callback for each line" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)

          send_response(client_socket, %{id: request["id"], type: "output", data: "line 1"})
          send_response(client_socket, %{id: request["id"], type: "output", data: "line 2"})
          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_output = fn line ->
        Agent.update(agent, fn lines -> [line | lines] end)
      end

      result =
        Seed.run_via_socket("nixos", "/nix/store/xyz",
          socket_path: socket_path,
          mode: "switch",
          on_output: on_output
        )

      assert {:ok, ["line 1", "line 2"]} = result

      collected = Agent.get(agent, fn lines -> Enum.reverse(lines) end)
      assert collected == ["line 1", "line 2"]
    end
  end

  describe "run_via_cli/3" do
    test "returns error when executables not found" do
      # Ensure the executables don't exist in PATH
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      on_exit(fn -> System.put_env("PATH", original_path) end)

      log =
        capture_log(fn ->
          result = Seed.run_via_cli("nixos", "/nix/store/xyz", mode: "switch")
          assert {:error, :cmd_not_found} = result
        end)

      assert log =~ "Failed to find required executables"
    end
  end

  # Helper functions for mock server

  defp start_mock_server(handler) do
    tmp_dir = Path.join(System.tmp_dir!(), "seed-test-#{:rand.uniform(100_000)}")
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
