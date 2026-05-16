defmodule SowerClient.ActivatorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias SowerClient.Activator

  describe "activate_via_socket/3" do
    test "successfully activates via socket" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "nixos"
          assert request["path"] == "/nix/store/xyz"
          assert request["mode"] == "switch"

          send_response(client_socket, %{id: request["id"], type: "output", data: "activating..."})

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      assert {:ok, ["activating..."]} =
               Activator.activate_via_socket("nixos", "/nix/store/xyz",
                 socket_path: socket_path,
                 mode: "switch"
               )
    end

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
        Activator.activate_via_socket("nixos", "/nix/store/xyz",
          socket_path: socket_path,
          mode: "switch",
          on_output: on_output
        )

      assert {:ok, ["line 1", "line 2"]} = result

      collected = Agent.get(agent, fn lines -> Enum.reverse(lines) end)
      assert collected == ["line 1", "line 2"]
    end

    test "returns error on activation failure" do
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

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      assert {:error, 1, ["permission denied"]} =
               Activator.activate_via_socket("nixos", "/nix/store/xyz", socket_path: socket_path)
    end

    test "returns error when socket not found" do
      assert {:error, :socket_not_found} =
               Activator.activate_via_socket("nixos", "/nix/store/xyz",
                 socket_path: "/nonexistent/socket"
               )
    end
  end

  describe "reboot_via_socket/1" do
    test "sends reboot request with reason" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "reboot"
          assert request["reason"] == "policy_always"
          refute Map.has_key?(request, "path")
          refute Map.has_key?(request, "mode")

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      assert {:ok, []} =
               Activator.reboot_via_socket(
                 socket_path: socket_path,
                 reason: "policy_always"
               )
    end
  end

  describe "activate_via_port/3" do
    test "returns error when executables not found" do
      # Ensure the executables don't exist in PATH
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      on_exit(fn -> System.put_env("PATH", original_path) end)

      log =
        capture_log(fn ->
          result = Activator.activate_via_port("nixos", "/nix/store/xyz", mode: "switch")
          assert {:error, :cmd_not_found} = result
        end)

      assert log =~ "Required executables not found"
    end

    test "activates via Port end-to-end (JSON-over-stdio)" do
      bin_dir = install_fake_sower(fake_sower_script_ok("ok line"))
      stub_path_user("alice", bin_dir)

      tags = [%{key: "username", value: "alice"}]

      assert {:ok, ["ok line"]} =
               Activator.activate_via_port("home-manager", "/nix/store/abc", tags: tags)
    end

    test "Port mode reports nonzero exit_code as error" do
      bin_dir = install_fake_sower(fake_sower_script_fail(42, "failure"))
      stub_path_user("alice", bin_dir)

      tags = [%{key: "username", value: "alice"}]

      assert {:error, 42, ["failure"]} =
               Activator.activate_via_port("home-manager", "/nix/store/abc", tags: tags)
    end

    test "Port mode streams output to on_output callback" do
      bin_dir =
        install_fake_sower(fake_sower_script_lines(["line one", "line two", "line three"], 0))

      stub_path_user("alice", bin_dir)

      {:ok, agent} = Agent.start_link(fn -> [] end)
      on_output = fn line -> Agent.update(agent, &[line | &1]) end

      tags = [%{key: "username", value: "alice"}]

      assert {:ok, ["line one", "line two", "line three"]} =
               Activator.activate_via_port("home-manager", "/nix/store/abc",
                 tags: tags,
                 on_output: on_output
               )

      assert ["line one", "line two", "line three"] == Agent.get(agent, &Enum.reverse/1)
    end
  end

  describe "activate/3" do
    test "uses socket when available" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      assert {:ok, []} =
               Activator.activate("nixos", "/nix/store/xyz", socket_path: socket_path)
    end

    test "falls back to Port when socket not available" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      on_exit(fn -> System.put_env("PATH", original_path) end)

      capture_log(fn ->
        result =
          Activator.activate("nixos", "/nix/store/xyz", socket_path: "/nonexistent/socket")

        assert {:error, :cmd_not_found} = result
      end)
    end

    test "home-manager with matching username bypasses socket" do
      {socket_path, server_pid} =
        start_mock_server(fn _request_line, _client_socket ->
          # This should not be called - we're testing the Port bypass
          flunk("Socket should not be contacted for same-user home-manager")
        end)

      original_user = System.get_env("USER")
      System.put_env("USER", "alice")

      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      on_exit(fn ->
        System.put_env("USER", original_user || "")
        System.put_env("PATH", original_path)
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      tags = [%{key: "username", value: "alice"}]

      capture_log(fn ->
        result =
          Activator.activate("home-manager", "/nix/store/xyz",
            socket_path: socket_path,
            tags: tags
          )

        assert {:error, :cmd_not_found} = result
      end)
    end

    test "home-manager with mismatched username fails without socket" do
      original_user = System.get_env("USER")
      System.put_env("USER", "alice")

      on_exit(fn -> System.put_env("USER", original_user || "") end)

      tags = [%{key: "username", value: "bob"}]

      capture_log(fn ->
        result =
          Activator.activate("home-manager", "/nix/store/xyz",
            socket_path: "/nonexistent/socket",
            tags: tags
          )

        assert {:error, :username_mismatch} = result
      end)
    end

    test "NixOS activation still uses socket when available" do
      {socket_path, server_pid} =
        start_mock_server(fn request_line, client_socket ->
          request = Jason.decode!(request_line)
          assert request["type"] == "nixos"

          send_response(client_socket, %{id: request["id"], type: "complete", exit_code: 0})
        end)

      on_exit(fn ->
        stop_mock_server(server_pid)
        File.rm_rf!(Path.dirname(socket_path))
      end)

      assert {:ok, []} =
               Activator.activate("nixos", "/nix/store/xyz", socket_path: socket_path)
    end

    test "home-manager without username tag returns appropriate error" do
      original_user = System.get_env("USER")
      System.put_env("USER", "alice")

      on_exit(fn -> System.put_env("USER", original_user || "") end)

      capture_log(fn ->
        result =
          Activator.activate("home-manager", "/nix/store/xyz",
            socket_path: "/nonexistent/socket",
            tags: []
          )

        assert {:error, :missing_username_tag} = result
      end)
    end
  end

  describe "reboot/1" do
    test "falls back to Port when socket is not available" do
      original_path = System.get_env("PATH")
      System.put_env("PATH", "/nonexistent")

      on_exit(fn -> System.put_env("PATH", original_path) end)

      capture_log(fn ->
        result =
          Activator.reboot(
            socket_path: "/nonexistent/socket",
            reason: "policy_always"
          )

        assert {:error, :cmd_not_found} = result
      end)
    end
  end

  describe "username_matches_current_user?/1" do
    test "returns true when username tag matches current user" do
      original_user = System.get_env("USER")
      System.put_env("USER", "alice")

      on_exit(fn -> System.put_env("USER", original_user || "") end)

      tags = [%{key: "username", value: "alice"}]
      assert Activator.username_matches_current_user?(tags)
    end

    test "returns false when username tag doesn't match current user" do
      original_user = System.get_env("USER")
      System.put_env("USER", "alice")

      on_exit(fn -> System.put_env("USER", original_user || "") end)

      tags = [%{key: "username", value: "bob"}]
      refute Activator.username_matches_current_user?(tags)
    end

    test "returns false when no username tag present" do
      refute Activator.username_matches_current_user?([])
      refute Activator.username_matches_current_user?([%{key: "other", value: "test"}])
    end
  end

  describe "socket_available?/1" do
    test "returns true when socket exists" do
      tmp_dir = Path.join(System.tmp_dir!(), "activator-test-#{:rand.uniform(100_000)}")
      socket_path = Path.join(tmp_dir, "activator.sock")
      File.mkdir_p!(tmp_dir)

      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      # Create a dummy file to simulate socket existence
      File.touch!(socket_path)

      assert Activator.socket_available?(socket_path)
    end

    test "returns false when socket does not exist" do
      refute Activator.socket_available?("/nonexistent/socket")
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

  # Helpers for Port-mode tests

  defp install_fake_sower(script_body) do
    bin_dir = Path.join(System.tmp_dir!(), "fake-sower-bin-#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(bin_dir)
    sower_path = Path.join(bin_dir, "sower-activator")
    File.write!(sower_path, script_body)
    File.chmod!(sower_path, 0o755)
    on_exit(fn -> File.rm_rf!(bin_dir) end)
    bin_dir
  end

  defp stub_path_user(username, bin_dir) do
    original_user = System.get_env("USER")
    original_path = System.get_env("PATH")
    System.put_env("USER", username)
    System.put_env("PATH", "#{bin_dir}:#{original_path}")

    on_exit(fn ->
      System.put_env("USER", original_user || "")
      System.put_env("PATH", original_path)
    end)
  end

  defp fake_sower_script_ok(line) do
    """
    #!/usr/bin/env bash
    set -u
    read -r request
    if [[ "$request" =~ \\"id\\":\\"([^\\"]+)\\" ]]; then
      id="${BASH_REMATCH[1]}"
    else
      id="unknown"
    fi
    printf '{"id":"%s","type":"output","data":"%s"}\\n' "$id" "#{line}"
    printf '{"id":"%s","type":"complete","exit_code":0}\\n' "$id"
    """
  end

  defp fake_sower_script_fail(exit_code, line) do
    """
    #!/usr/bin/env bash
    set -u
    read -r request
    if [[ "$request" =~ \\"id\\":\\"([^\\"]+)\\" ]]; then
      id="${BASH_REMATCH[1]}"
    else
      id="unknown"
    fi
    printf '{"id":"%s","type":"error","data":"%s"}\\n' "$id" "#{line}"
    printf '{"id":"%s","type":"complete","exit_code":%d}\\n' "$id" #{exit_code}
    """
  end

  defp fake_sower_script_lines(lines, exit_code) do
    line_emits =
      lines
      |> Enum.map(fn line ->
        ~s(printf '{"id":"%s","type":"output","data":"#{line}"}\\n' "$id")
      end)
      |> Enum.join("\n")

    """
    #!/usr/bin/env bash
    set -u
    read -r request
    if [[ "$request" =~ \\"id\\":\\"([^\\"]+)\\" ]]; then
      id="${BASH_REMATCH[1]}"
    else
      id="unknown"
    fi
    #{line_emits}
    printf '{"id":"%s","type":"complete","exit_code":%d}\\n' "$id" #{exit_code}
    """
  end
end
