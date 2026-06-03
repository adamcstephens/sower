defmodule Garden.AdminSocketTest do
  use ExUnit.Case, async: true

  alias Garden.AdminSocket
  alias Garden.AdminSocket.{Creds, Policy}
  alias SowerClient.Admin

  describe "authorized?/2" do
    test "authorizes a matching uid" do
      creds = %Creds{pid: 1, uid: 1000, gid: 50}
      policy = %Policy{allowed_uids: [0, 1000], allowed_gids: [999]}
      assert AdminSocket.authorized?(creds, policy)
    end

    test "authorizes a matching gid" do
      creds = %Creds{pid: 1, uid: 1234, gid: 999}
      policy = %Policy{allowed_uids: [0], allowed_gids: [999]}
      assert AdminSocket.authorized?(creds, policy)
    end

    test "rejects when neither uid nor gid match" do
      creds = %Creds{pid: 1, uid: 1234, gid: 50}
      policy = %Policy{allowed_uids: [0], allowed_gids: [999]}
      refute AdminSocket.authorized?(creds, policy)
    end
  end

  describe "request dispatch" do
    test "streams an ok then complete frame for an ok result" do
      test_pid = self()

      path =
        start_socket(fn request ->
          send(test_pid, {:handled, request})
          {:ok, "deployment enqueued"}
        end)

      frames =
        request(path, %{
          "v" => 1,
          "id" => "req-1",
          "kind" => "deploy",
          "seed_type" => "nixos",
          "force" => true
        })

      assert_received {:handled, %Admin.Request{} = request}
      assert request.kind == "deploy"
      assert request.seed_type == "nixos"
      assert request.force == true

      assert [ok, complete] = frames
      assert ok == %{"v" => 1, "id" => "req-1", "kind" => "ok", "data" => "deployment enqueued"}
      assert complete == %{"v" => 1, "id" => "req-1", "kind" => "complete", "exit_code" => 0}
    end

    test "streams an error then non-zero complete for an error result" do
      path = start_socket(fn _ -> {:error, "subscription not found"} end)

      assert [error, complete] = request(path, %{"id" => "req-2", "kind" => "deploy"})

      assert error == %{
               "v" => 1,
               "id" => "req-2",
               "kind" => "error",
               "data" => "subscription not found"
             }

      assert complete == %{"v" => 1, "id" => "req-2", "kind" => "complete", "exit_code" => 1}
    end

    test "encodes a status payload on the ok frame" do
      status = Admin.Status.cast!(%{version: "9.9.9", active_deployments: ["dep-1"]})
      path = start_socket(fn _ -> {:status, status} end)

      assert [ok, complete] = request(path, %{"id" => "req-3", "kind" => "status"})

      assert ok == %{
               "v" => 1,
               "id" => "req-3",
               "kind" => "ok",
               "status" => %{"version" => "9.9.9", "active_deployments" => ["dep-1"]}
             }

      assert complete["kind"] == "complete"
      assert complete["exit_code"] == 0
    end

    test "drops the connection on an over-long request line" do
      path = start_socket(fn _ -> {:ok, "unreachable"} end)

      oversized = %{"id" => "req-4", "kind" => "deploy", "sid" => String.duplicate("x", 70_000)}

      # The connection is dropped without any reply frame.
      assert request(path, oversized) == []
    end

    test "rejects malformed JSON" do
      path = start_socket(fn _ -> {:ok, "unreachable"} end)

      socket = connect(path)
      :gen_tcp.send(socket, ["not json\n"])
      frames = recv_frames(socket)
      :gen_tcp.close(socket)

      assert [error, complete] = frames
      assert error["kind"] == "error"
      assert error["data"] =~ "invalid request"
      assert complete["exit_code"] == 1
    end

    test "default handler reports the garden version on status" do
      path = start_socket(&Garden.Admin.handle/1)

      assert [ok, _complete] = request(path, %{"id" => "req-5", "kind" => "status"})
      assert ok["kind"] == "ok"
      assert ok["status"]["version"] == to_string(Application.spec(:garden, :vsn))
      assert ok["status"]["active_deployments"] == []
    end
  end

  defp start_socket(handler) do
    tmp = Path.join(System.tmp_dir!(), "admin-socket-#{System.unique_integer([:positive])}")
    path = Path.join(tmp, "admin.sock")

    {:ok, pid} = AdminSocket.start_link(name: nil, socket_path: path, handler: handler)

    on_exit(fn ->
      # The socket is linked to the (now-exited) test process, so it may already
      # be terminating; cleanup is best-effort.
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end

      File.rm_rf!(tmp)
    end)

    path
  end

  defp request(path, payload) do
    socket = connect(path)
    :gen_tcp.send(socket, [Jason.encode!(payload), "\n"])
    frames = recv_frames(socket)
    :gen_tcp.close(socket)
    frames
  end

  defp connect(path) do
    {:ok, socket} =
      :gen_tcp.connect({:local, path}, 0, [:binary, {:active, false}, {:packet, :line}])

    socket
  end

  defp recv_frames(socket, acc \\ []) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, line} ->
        frame = line |> String.trim_trailing("\n") |> Jason.decode!()
        acc = [frame | acc]

        if frame["kind"] == "complete" do
          Enum.reverse(acc)
        else
          recv_frames(socket, acc)
        end

      {:error, :closed} ->
        Enum.reverse(acc)
    end
  end
end
