defmodule Garden.AdminSocket do
  @moduledoc """
  Unix-domain admin socket served by the garden BEAM.

  The garden is long-running, so it binds the socket itself on startup — the
  inverse of the activator, where the Rust CLI is the per-connection server
  spawned by systemd socket activation. The `sower` CLI connects, sends a single
  newline-delimited compact JSON request envelope, and streams reply frames back
  (`ok`/`error` then a terminal `complete` carrying an exit code).

  Auth is SO_PEERCRED, mirroring the activator: a peer is authorized when its uid
  is root or the socket owner, or its gid matches the socket group. The listener
  caps line length so an over-long request is rejected rather than buffered.

  It starts unconditionally (unlike the websocket client) so admin commands work
  even when the garden is disconnected from its server.
  """

  use GenServer
  use TypedStruct

  require Logger

  alias SowerClient.Admin

  # Linux SO_PEERCRED: getsockopt(SOL_SOCKET=1, SO_PEERCRED=17) -> struct ucred
  # { pid_t pid; uid_t uid; gid_t gid; } == 12 bytes, native byte order.
  @sol_socket 1
  @so_peercred 17
  @ucred_size 12

  # Reject any request line longer than this; the Rust client mirrors the cap.
  @max_line_bytes 65_536
  @recv_timeout 5_000
  @socket_mode 0o660

  typedstruct module: Creds do
    field :pid, integer()
    field :uid, integer(), enforce: true
    field :gid, integer(), enforce: true
  end

  typedstruct module: Policy do
    field :allowed_uids, list(integer()), default: []
    field :allowed_gids, list(integer()), default: []
  end

  typedstruct module: State do
    field :listen_socket, :gen_tcp.socket(), enforce: true
    field :socket_path, String.t(), enforce: true
    field :acceptor, pid(), enforce: true
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Whether a peer's credentials satisfy the socket's authorization policy.
  """
  def authorized?(%Creds{uid: uid, gid: gid}, %Policy{allowed_uids: uids, allowed_gids: gids}) do
    uid in uids or gid in gids
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    socket_path = Keyword.get(opts, :socket_path) || configured_socket_path()
    handler = Keyword.get(opts, :handler, &Garden.Admin.handle/1)

    case start_listening(socket_path) do
      {:ok, listen, policy} ->
        acceptor = spawn_link(fn -> accept_loop(listen, policy, handler) end)
        Logger.info(msg: "admin socket listening", path: socket_path)
        {:ok, %State{listen_socket: listen, socket_path: socket_path, acceptor: acceptor}}

      {:error, reason} ->
        # Never strand the garden over the admin socket: log loudly and keep the
        # rest of the supervision tree running.
        Logger.error(
          msg: "admin socket failed to start",
          path: socket_path,
          reason: inspect(reason)
        )

        :ignore
    end
  end

  @impl GenServer
  def handle_info({:EXIT, acceptor, reason}, %State{acceptor: acceptor} = state) do
    {:stop, reason, state}
  end

  @impl GenServer
  def terminate(_reason, %State{listen_socket: listen, socket_path: socket_path}) do
    :gen_tcp.close(listen)
    _ = File.rm(socket_path)
    :ok
  end

  #
  # listener setup
  #

  defp start_listening(socket_path) do
    with :ok <- prepare_path(socket_path),
         {:ok, listen} <- listen(socket_path),
         :ok <- File.chmod(socket_path, @socket_mode),
         {:ok, policy} <- build_policy(socket_path) do
      {:ok, listen, policy}
    else
      {:error, _} = err -> err
    end
  end

  defp prepare_path(socket_path) do
    case File.mkdir_p(Path.dirname(socket_path)) do
      :ok ->
        # A leftover socket file from an unclean shutdown blocks rebinding.
        _ = File.rm(socket_path)
        :ok

      {:error, _} = err ->
        err
    end
  end

  defp listen(socket_path) do
    :gen_tcp.listen(0, [
      {:ifaddr, {:local, socket_path}},
      :binary,
      {:active, false},
      {:packet, :line},
      {:packet_size, @max_line_bytes},
      # buffer must exceed packet_size so an over-long line is rejected with
      # :emsgsize rather than silently truncated at the default buffer size.
      {:buffer, @max_line_bytes * 2},
      {:reuseaddr, true}
    ])
  end

  defp build_policy(socket_path) do
    case File.stat(socket_path) do
      {:ok, %File.Stat{uid: uid, gid: gid}} ->
        {:ok, %Policy{allowed_uids: Enum.uniq([0, uid]), allowed_gids: [gid]}}

      {:error, _} = err ->
        err
    end
  end

  #
  # accept / per-connection handling
  #

  defp accept_loop(listen, policy, handler) do
    case :gen_tcp.accept(listen) do
      {:ok, client} ->
        spawn_handler(client, policy, handler)
        accept_loop(listen, policy, handler)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.warning(msg: "admin socket accept failed", reason: inspect(reason))
        :ok
    end
  end

  defp spawn_handler(client, policy, handler) do
    # Plain spawn (not linked) so a misbehaving connection can't take down the
    # acceptor. Hand the socket to the new owner before it reads.
    pid =
      spawn(fn ->
        receive do
          {:go, socket} -> handle_connection(socket, policy, handler)
        end
      end)

    case :gen_tcp.controlling_process(client, pid) do
      :ok -> send(pid, {:go, client})
      {:error, _} -> :gen_tcp.close(client)
    end
  end

  defp handle_connection(client, policy, handler) do
    outcome =
      case peercred(client) do
        {:ok, creds} ->
          if authorized?(creds, policy) do
            authorized_outcome(client, handler)
          else
            Logger.warning(
              msg: "admin socket rejected peer",
              uid: to_string(creds.uid),
              gid: to_string(creds.gid)
            )

            {:reply_error, "", "unauthorized"}
          end

        {:error, reason} ->
          Logger.warning(msg: "admin socket peercred failed", reason: inspect(reason))
          {:reply_error, "", "unauthorized"}
      end

    emit(client, outcome)
    :gen_tcp.close(client)
  end

  defp authorized_outcome(client, handler) do
    case read_request(client) do
      {:ok, request} ->
        {:dispatch, request.id, handler.(request)}

      # An over-long line puts the OTP socket into :enotconn, so we can't reply —
      # just drop the connection (the Rust client enforces the same cap).
      {:error, :emsgsize} ->
        {:disconnect, "request exceeds #{@max_line_bytes} byte limit"}

      {:error, reason} ->
        {:reply_error, "", "invalid request: #{inspect(reason)}"}
    end
  end

  defp emit(_client, {:disconnect, reason}) do
    Logger.warning(
      msg: "admin socket dropped over-long request",
      limit: @max_line_bytes,
      detail: reason
    )

    :ok
  end

  defp emit(client, {:dispatch, id, {:ok, message}}),
    do: send_frames(client, id, :ok, %{"data" => message})

  defp emit(client, {:dispatch, id, {:error, message}}),
    do: send_frames(client, id, :error, %{"data" => message})

  defp emit(client, {:dispatch, id, {:status, %Admin.Status{} = status}}),
    do: send_frames(client, id, :ok, %{"status" => status_map(status)})

  defp emit(client, {:reply_error, id, message}),
    do: send_frames(client, id, :error, %{"data" => message})

  defp send_frames(client, id, :ok, extra) do
    write_frame(client, Map.merge(%{"v" => 1, "id" => id, "kind" => "ok"}, extra))
    write_frame(client, complete_frame(id, 0))
  end

  defp send_frames(client, id, :error, extra) do
    write_frame(client, Map.merge(%{"v" => 1, "id" => id, "kind" => "error"}, extra))
    write_frame(client, complete_frame(id, 1))
  end

  defp complete_frame(id, exit_code) do
    %{"v" => 1, "id" => id, "kind" => "complete", "exit_code" => exit_code}
  end

  defp status_map(%Admin.Status{version: version, active_deployments: active}) do
    %{"version" => version, "active_deployments" => active}
  end

  defp write_frame(client, frame) do
    :gen_tcp.send(client, [Jason.encode!(frame), "\n"])
  end

  defp read_request(client) do
    case :gen_tcp.recv(client, 0, @recv_timeout) do
      {:ok, line} ->
        line |> String.trim_trailing("\n") |> decode_request()

      {:error, _} = err ->
        err
    end
  end

  defp decode_request(line) do
    case Jason.decode(line) do
      {:ok, map} ->
        case Admin.Request.cast(map) do
          {:ok, request} -> {:ok, request}
          {:error, errors} -> {:error, {:cast, errors}}
        end

      {:error, reason} ->
        {:error, {:json, reason}}
    end
  end

  defp peercred(client) do
    case :inet.getopts(client, [{:raw, @sol_socket, @so_peercred, @ucred_size}]) do
      {:ok,
       [
         {:raw, @sol_socket, @so_peercred,
          <<pid::native-signed-32, uid::native-unsigned-32, gid::native-unsigned-32>>}
       ]} ->
        {:ok, %Creds{pid: pid, uid: uid, gid: gid}}

      other ->
        {:error, {:peercred, other}}
    end
  end

  defp configured_socket_path do
    case Garden.Config.get() do
      %SowerClient.Config{admin_socket: path} when is_binary(path) -> path
      _ -> SowerClient.Config.default_admin_socket()
    end
  end
end
