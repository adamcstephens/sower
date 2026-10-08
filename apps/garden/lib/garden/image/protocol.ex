defmodule Garden.Image.Protocol do
  @moduledoc false
  @maximum 65_536

  def decode_frame(bytes) when byte_size(bytes) < 5, do: :more

  def decode_frame(<<kind, length::unsigned-big-32, rest::binary>>) do
    cond do
      length > @maximum ->
        {:error, {:frame_too_large, length}}

      kind not in [1, 2, 3] ->
        {:error, {:unknown_frame_kind, kind}}

      byte_size(rest) < length ->
        :more

      true ->
        <<payload::binary-size(^length), remaining::binary>> = rest

        case event(kind, payload) do
          {:ok, event} -> {:ok, event, remaining}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def execute(%Garden.Image.Command{} = command) do
    with {:ok, payload} <-
           Jason.encode(%{
             "type" => "execute",
             "version" => 1,
             "path" => command.path,
             "args" => command.args,
             "env" => command.env,
             "stdin" => command.stdin
           }),
         true <- byte_size(payload) <= @maximum do
      {:ok, <<1, byte_size(payload)::unsigned-big-32, payload::binary>>}
    else
      false -> {:error, :request_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  def recv(socket) do
    with {:ok, <<kind, length::unsigned-big-32>> = header} <- :gen_tcp.recv(socket, 5),
         :more <- decode_frame(header),
         {:ok, payload} <- payload(socket, length),
         {:ok, event} <- event(kind, payload) do
      {:ok, event, <<>>}
    else
      {:ok, event, <<>>} -> {:ok, event, <<>>}
      {:error, reason} -> {:error, reason}
    end
  end

  defp payload(_socket, 0), do: {:ok, <<>>}
  defp payload(socket, length), do: :gen_tcp.recv(socket, length)
  defp event(2, bytes), do: {:ok, {:stdout, bytes}}
  defp event(3, bytes), do: {:ok, {:stderr, bytes}}

  defp event(1, bytes) do
    case Jason.decode(bytes) do
      {:ok, %{"version" => version}} when version != 1 ->
        {:error, {:unsupported_event_version, version}}

      {:ok, %{"version" => 1} = metadata} ->
        metadata(metadata)

      {:ok, _} ->
        {:error, :invalid_metadata_event}

      {:error, _} ->
        {:error, :invalid_metadata_json}
    end
  end

  defp metadata(%{"type" => "ready"}), do: {:ok, :ready}

  defp metadata(%{"type" => "exited", "code" => code, "signal" => nil})
       when is_integer(code) and code >= 0 and code <= 255,
       do: {:ok, {:exited, code, nil}}

  defp metadata(%{"type" => "exited", "code" => nil, "signal" => signal})
       when is_integer(signal) and signal > 0 and signal <= 64,
       do: {:ok, {:exited, nil, signal}}

  defp metadata(%{"type" => "exited"}), do: {:error, :invalid_exit_status}

  defp metadata(%{"type" => "error", "message" => message}) when is_binary(message),
    do: {:ok, {:guest_error, message}}

  defp metadata(%{"type" => "error"}), do: {:error, :invalid_error_event}
  defp metadata(%{"type" => type}), do: {:error, {:unknown_event_type, type}}
  defp metadata(_), do: {:error, :invalid_metadata_event}
end
