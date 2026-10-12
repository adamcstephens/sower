defmodule Garden.VM.IO do
  @moduledoc false
  alias Garden.VM.Protocol

  def output(:stdout, bytes), do: IO.binwrite(:stdio, bytes)
  def output(:stderr, bytes), do: IO.binwrite(:standard_error, bytes)

  def run(guard, vmm, %Garden.VM.Command{} = command, callback, started) do
    result =
      with {:ok, status} <- CloudHypervisor.Process.await_ready(vmm),
           {:ok, socket} <- connect(Path.join(status.directory, "vsock.sock")) do
        try do
          with {:ok, :ready, <<>>} <- Protocol.recv(socket),
               {:ok, frame} <- Protocol.execute(command),
               :ok <- :gen_tcp.send(socket, frame) do
            ready = System.monotonic_time(:millisecond) - started
            send(guard, {:guest_ready, ready})
            drain(socket, callback, ready, started)
          else
            {:error, reason} -> {:error, reason}
            event -> {:error, {:unexpected_ready_event, event}}
          end
        after
          :gen_tcp.close(socket)
        end
      else
        {:error, reason} -> {:error, reason}
      end

    send(guard, {:finish, result})
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

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, {:bridge, reason}}

          false ->
            :gen_tcp.close(socket)
            {:error, :invalid_bridge_handshake}
        end

      {:error, reason} when reason in [:enoent, :econnrefused] ->
        Process.sleep(25)
        connect(path)

      {:error, reason} ->
        {:error, {:bridge, reason}}
    end
  end

  defp drain(socket, callback, ready, started) do
    case Protocol.recv(socket) do
      {:ok, {stream, bytes}, <<>>} when stream in [:stdout, :stderr] ->
        callback.(stream, bytes)
        drain(socket, callback, ready, started)

      {:ok, {:exited, code, signal}, <<>>} ->
        {:ok,
         %Garden.VM.Result{
           code: code,
           signal: signal,
           ready_ms: ready,
           elapsed_ms: System.monotonic_time(:millisecond) - started
         }}

      {:ok, {:guest_error, message}, <<>>} ->
        {:error, {:guest, message}}

      {:ok, event, <<>>} ->
        {:error, {:unexpected_guest_event, event}}

      {:error, reason} ->
        {:error, {:guest_protocol, reason}}
    end
  end
end
