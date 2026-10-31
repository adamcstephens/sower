defmodule VMManager.IO do
  @moduledoc false
  use TypedStruct
  alias VMManager.Protocol

  typedstruct do
    field :guard, pid(), enforce: true
    field :path, String.t(), enforce: true
    field :contract, integer(), enforce: true
    field :socket, port()
    field :command, pid()
    field :callback, function()
    field :worker, pid()
    field :buffer, binary(), default: <<>>
    field :cancelled, term()
    field :started, integer()
    field :ready_ms, integer()
  end

  def output(:stdout, bytes), do: IO.binwrite(:stdio, bytes)
  def output(:stderr, bytes), do: IO.binwrite(:standard_error, bytes)

  def run(guard, path, contract, started) when is_binary(path) do
    Process.flag(:trap_exit, true)

    with {:ok, socket} <- connect(path),
         :ok <- ready(socket, contract) do
      elapsed = System.monotonic_time(:millisecond) - started
      send(guard, {:guest_ready, elapsed})

      idle(%__MODULE__{
        guard: guard,
        path: path,
        contract: contract,
        socket: socket,
        ready_ms: elapsed
      })
    else
      {:error, reason} -> send(guard, {:finish, {:error, reason}})
    end
  end

  defp idle(%__MODULE__{} = state) do
    receive do
      {:execute, command, request, callback} ->
        state = %{
          state
          | command: command,
            callback: callback,
            started: System.monotonic_time(:millisecond),
            cancelled: nil,
            buffer: <<>>
        }

        with {:ok, socket} <- connection(state),
             {:ok, frame} <- Protocol.execute(request, state.contract),
             :ok <- :gen_tcp.send(socket, frame),
             :ok <- :inet.setopts(socket, active: :once) do
          receive_output(%{state | socket: socket})
        else
          {:error, reason} -> send(state.guard, {:finish, {:error, {:guest_connection, reason}}})
        end
    end
  end

  defp connection(%__MODULE__{socket: socket}) when not is_nil(socket), do: {:ok, socket}

  defp connection(%__MODULE__{} = state) do
    with {:ok, socket} <- connect(state.path),
         :ok <- ready(socket, state.contract) do
      {:ok, socket}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp ready(socket, contract) do
    case Protocol.recv(socket) do
      {:ok, {:ready, 2}, <<>>} when contract == 2 -> :ok
      {:ok, :ready, <<>>} when contract == 1 -> :ok
      {:ok, {:ready, 2}, <<>>} when contract == 1 -> :ok
      event -> {:error, {:unexpected_ready_event, event}}
    end
  end

  defp receive_output(%__MODULE__{} = state) do
    receive do
      {:tcp, socket, bytes} when socket == state.socket ->
        consume(%{state | buffer: state.buffer <> bytes})

      {:tcp_closed, socket} when socket == state.socket ->
        reconnect(state, :guest_disconnected)

      {:tcp_error, socket, reason} when socket == state.socket ->
        reconnect(state, {:guest_connection, reason})

      {:output_done, worker} when worker == state.worker ->
        consume(%{state | worker: nil})

      {:EXIT, worker, _reason} when worker == state.worker ->
        send(state.guard, {:cancel_command, state.command, :output_consumer_down})
        receive_output(%{state | worker: nil})

      {:cancel, command, reason} when command == state.command ->
        cancel(state, reason)

      _ ->
        receive_output(state)
    end
  end

  defp cancel(%__MODULE__{cancelled: reason} = state, _new) when not is_nil(reason),
    do: receive_output(state)

  defp cancel(%__MODULE__{} = state, reason) do
    if state.worker, do: Process.exit(state.worker, :kill)

    if state.contract == 2 do
      case :gen_tcp.send(state.socket, Protocol.cancel()) do
        :ok -> consume(%{state | worker: nil, cancelled: reason})
        {:error, error} -> send(state.guard, {:finish, {:error, {:cancel_unconfirmed, error}}})
      end
    else
      send(state.guard, {:finish, {:error, reason}})
    end
  end

  defp consume(%__MODULE__{worker: worker} = state) when not is_nil(worker),
    do: receive_output(state)

  defp consume(%__MODULE__{} = state) do
    case Protocol.decode_frame(state.buffer) do
      :more ->
        :ok = :inet.setopts(state.socket, active: :once)
        receive_output(state)

      {:ok, {stream, bytes}, rest} when stream in [:stdout, :stderr] ->
        if state.cancelled do
          consume(%{state | buffer: rest})
        else
          io = self()
          callback = state.callback

          worker =
            spawn_link(fn ->
              callback.(stream, bytes)
              send(io, {:output_done, self()})
            end)

          receive_output(%{state | buffer: rest, worker: worker})
        end

      {:ok, {:exited, code, signal}, _rest} ->
        result =
          if state.cancelled,
            do: {:error, state.cancelled},
            else:
              {:ok,
               %VMManager.Result{
                 code: code,
                 signal: signal,
                 ready_ms: state.ready_ms,
                 elapsed_ms: System.monotonic_time(:millisecond) - state.started
               }}

        completed(state, result)

      {:ok, {:guest_error, message}, _rest} ->
        completed(state, {:error, {:guest, message}})

      event ->
        send(state.guard, {:finish, {:error, {:guest_protocol, event}}})
    end
  end

  defp reconnect(%__MODULE__{contract: 2} = state, reason) do
    :gen_tcp.close(state.socket)
    if state.worker, do: Process.exit(state.worker, :kill)
    send(state.guard, {:guest_reconnecting, state.command})

    case connection(%{state | socket: nil}) do
      {:ok, socket} ->
        send(state.guard, {:command_finished, state.command, {:error, state.cancelled || reason}})
        idle(%{state | socket: socket, command: nil, callback: nil, buffer: <<>>, worker: nil})

      {:error, error} ->
        send(state.guard, {:finish, {:error, {:reconnect_unconfirmed, error}}})
    end
  end

  defp reconnect(%__MODULE__{} = state, reason),
    do: send(state.guard, {:finish, {:error, reason}})

  defp completed(%__MODULE__{} = state, result) do
    :gen_tcp.close(state.socket)
    send(state.guard, {:command_finished, state.command, result})
    idle(%{state | socket: nil, command: nil, callback: nil, buffer: <<>>})
  end

  defp connect(path) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, active: false, packet: :line, packet_size: 128],
           1_000
         ) do
      {:ok, socket} ->
        with :ok <- :gen_tcp.send(socket, "CONNECT 5000\n"),
             {:ok, line} <- :gen_tcp.recv(socket, 0, 1_000),
             true <- Regex.match?(~r/\AOK [0-9]+\n\z/, line),
             :ok <- :inet.setopts(socket, packet: :raw) do
          {:ok, socket}
        else
          {:error, reason} when reason in [:closed, :econnrefused, :timeout] ->
            :gen_tcp.close(socket)
            Process.sleep(25)
            connect(path)

          error ->
            :gen_tcp.close(socket)
            {:error, {:bridge, error}}
        end

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        Process.sleep(25)
        connect(path)

      {:error, reason} ->
        {:error, {:bridge, reason}}
    end
  end
end
