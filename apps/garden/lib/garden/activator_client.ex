defmodule Garden.ActivatorClient do
  @moduledoc """
  Client for communicating with sower-activator via Unix domain socket.

  Sends activation requests and streams responses back to the caller.
  """

  use TypedStruct

  require Logger

  @default_socket_path "/run/sower-activator/activator.sock"
  @connect_timeout 5_000
  @recv_timeout 300_000
  @network_recv_timeout 5_000

  typedstruct module: Request do
    field :id, String.t(), enforce: true
    field :type, String.t(), enforce: true
    field :path, String.t()
    field :mode, String.t()
    field :network_action, String.t()
    field :execution_id, String.t()
    field :lease, String.t()
  end

  typedstruct module: Response do
    field :id, String.t(), enforce: true
    field :type, String.t(), enforce: true
    field :data, String.t()
    field :exit_code, integer()
  end

  @doc """
  Activates a NixOS or home-manager configuration via the activator socket.

  Returns `{:ok, output_lines}` on success, `{:error, reason}` on failure.
  The `on_output` callback is invoked for each output line as it arrives.
  """
  def activate(type, path, opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)
    mode = Keyword.get(opts, :mode)
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)

    request = %Request{
      id: generate_request_id(),
      type: type,
      path: path,
      mode: mode
    }

    exchange(request, socket_path, on_output)
  end

  def network(action, opts \\ []) do
    request = %Request{
      id: generate_request_id(),
      type: "network",
      network_action: to_string(action),
      execution_id: Keyword.get(opts, :execution_id),
      lease: Keyword.get(opts, :lease)
    }

    case exchange(
           request,
           Keyword.get(opts, :socket_path, @default_socket_path),
           fn _ -> :ok end,
           @network_recv_timeout
         ) do
      {:ok, [data]} when action in [:provision, "provision"] ->
        with {:ok, json} <- Jason.decode(data),
             {:ok, lease} <- SowerClient.Activator.NetworkLease.cast(json) do
          {:ok, lease}
        else
          {:error, reason} -> {:error, {:network_protocol, reason}}
        end

      {:ok, _} when action in [:provision, "provision"] ->
        {:error, {:network_protocol, :missing_lease}}

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exchange(%Request{} = request, socket_path, on_output, timeout \\ @recv_timeout) do
    with {:ok, socket} <- connect(socket_path) do
      try do
        with :ok <- send_request(socket, request) do
          receive_responses(socket, request.id, on_output, timeout)
        else
          {:error, reason} -> {:error, reason}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp connect(socket_path) do
    case :gen_tcp.connect(
           {:local, socket_path},
           0,
           [:binary, {:active, false}, {:packet, :line}],
           @connect_timeout
         ) do
      {:ok, socket} ->
        {:ok, socket}

      {:error, :enoent} ->
        {:error, :socket_not_found}

      {:error, :econnrefused} ->
        {:error, :connection_refused}

      {:error, reason} ->
        Logger.error(
          msg: "Failed to connect to activator socket",
          reason: reason,
          path: socket_path
        )

        {:error, {:connect_failed, reason}}
    end
  end

  defp send_request(socket, %Request{} = request) do
    payload = encode_request(request)

    case :gen_tcp.send(socket, [payload, "\n"]) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error(msg: "Failed to send request to activator", reason: reason)
        {:error, {:send_failed, reason}}
    end
  end

  defp encode_request(%Request{} = request) do
    map =
      %{
        "id" => request.id,
        "type" => request.type
      }
      |> maybe_put("path", request.path)
      |> maybe_put("mode", request.mode)
      |> maybe_put("network_action", request.network_action)
      |> maybe_put("execution_id", request.execution_id)
      |> maybe_put("lease", request.lease)

    Jason.encode!(map)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp receive_responses(socket, request_id, on_output, timeout) do
    receive_loop(socket, request_id, on_output, [], timeout)
  end

  defp receive_loop(socket, request_id, on_output, acc, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, line} ->
        case parse_response(line) do
          {:ok, %Response{id: ^request_id} = response} ->
            handle_response(socket, response, on_output, acc, timeout)

          {:ok, %Response{id: other_id}} ->
            Logger.warning(
              msg: "Received response for wrong request",
              expected: request_id,
              got: other_id
            )

            receive_loop(socket, request_id, on_output, acc, timeout)

          {:error, reason} ->
            Logger.error(msg: "Failed to parse response", reason: reason, line: line)
            {:error, {:parse_failed, reason}}
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :closed} ->
        {:error, :connection_closed}

      {:error, reason} ->
        Logger.error(msg: "Failed to receive from activator", reason: reason)
        {:error, {:recv_failed, reason}}
    end
  end

  defp handle_response(socket, %Response{type: "output"} = response, on_output, acc, timeout) do
    on_output.(response.data)
    receive_loop(socket, response.id, on_output, [response.data | acc], timeout)
  end

  defp handle_response(socket, %Response{type: "error"} = response, on_output, acc, timeout) do
    on_output.(response.data)
    receive_loop(socket, response.id, on_output, [response.data | acc], timeout)
  end

  defp handle_response(_socket, %Response{type: "complete"} = response, _on_output, acc, _timeout) do
    output = Enum.reverse(acc)

    case response.exit_code do
      0 -> {:ok, output}
      code -> {:error, {:activation_failed, code, output}}
    end
  end

  defp handle_response(socket, %Response{} = response, on_output, acc, timeout) do
    Logger.warning(msg: "Unknown response type", type: response.type)
    receive_loop(socket, response.id, on_output, acc, timeout)
  end

  defp parse_response(line) do
    line = String.trim_trailing(line, "\n")

    case Jason.decode(line) do
      {:ok, %{"id" => id, "type" => type} = data} ->
        response = %Response{
          id: id,
          type: type,
          data: data["data"],
          exit_code: data["exit_code"]
        }

        {:ok, response}

      {:ok, _data} ->
        {:error, :missing_required_gardens}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp generate_request_id do
    SowerClient.Sid.generate("act")
  end

  @doc """
  Checks if the activator socket is available.
  """
  def socket_available?(socket_path \\ @default_socket_path) do
    File.exists?(socket_path)
  end
end
