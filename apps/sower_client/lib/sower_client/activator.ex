defmodule SowerClient.Activator do
  @moduledoc """
  Activate Nix configurations (NixOS, home-manager) via sower-activator.

  Supports two activation methods:
  - Socket mode: Communicates with sower-activator daemon via Unix socket
  - CLI mode: Invokes sower-activator binary directly (with sudo)

  The `activate/3` function automatically tries socket first, then falls back to CLI.
  """

  use TypedStruct

  require Logger

  @default_socket_path "/run/sower-activator/activator.sock"
  @connect_timeout 5_000
  @recv_timeout 300_000

  typedstruct module: Request do
    field(:id, String.t(), enforce: true)
    field(:type, String.t(), enforce: true)
    field(:path, String.t(), enforce: true)
    field(:mode, String.t())
  end

  typedstruct module: Response do
    field(:id, String.t(), enforce: true)
    field(:type, String.t(), enforce: true)
    field(:data, String.t())
    field(:exit_code, integer())
  end

  @doc """
  Activate a configuration via socket or CLI fallback.

  Tries socket activation first (if available), falls back to CLI if socket unavailable.

  ## Options

  - `:socket_path` - Path to activator socket (default: #{@default_socket_path})
  - `:mode` - Activation mode (e.g., "switch", "boot", "test")
  - `:on_output` - Callback function for streaming output: `(String.t() -> any())`

  ## Returns

  - `{:ok, output_lines}` - Success with output lines as strings
  - `{:error, reason}` - Connection/socket error
  - `{:error, exit_code, output}` - Activation failed with exit code
  """
  def activate(type, path, opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)

    if socket_available?(socket_path) do
      activate_via_socket(type, path, opts)
    else
      Logger.debug("Socket not available, falling back to CLI activation")
      activate_via_cli(type, path, opts)
    end
  end

  @doc """
  Activate via Unix socket connection to sower-activator daemon.

  ## Options

  - `:socket_path` - Path to activator socket (default: #{@default_socket_path})
  - `:mode` - Activation mode
  - `:on_output` - Callback function for streaming output

  ## Returns

  - `{:ok, output_lines}` - Success
  - `{:error, reason}` - Connection/protocol error
  - `{:error, exit_code, output}` - Activation failed
  """
  def activate_via_socket(type, path, opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)
    mode = Keyword.get(opts, :mode)
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)

    request = %Request{
      id: generate_request_id(),
      type: type,
      path: path,
      mode: mode
    }

    with {:ok, socket} <- connect(socket_path),
         :ok <- send_request(socket, request),
         result <- receive_responses(socket, request.id, on_output) do
      :gen_tcp.close(socket)
      result
    end
  end

  @doc """
  Activate via CLI invocation of sower-activator binary.

  Requires `sudo` and `sower-activator` in PATH. Invokes:
  `sudo sower-activator -type TYPE -path PATH [-mode MODE]`

  ## Options

  - `:mode` - Activation mode

  ## Returns

  - `{:ok, output_lines}` - Success
  - `{:error, :cmd_not_found}` - Required executables not found
  - `{:error, exit_code, output}` - Command failed
  """
  def activate_via_cli(type, path, opts \\ []) do
    args = build_cli_args(type, path, opts)

    with activator when not is_nil(activator) <- System.find_executable("sower-activator"),
         sudo when not is_nil(sudo) <- System.find_executable("sudo") do
      case System.cmd(sudo, [activator | args],
             into: [],
             lines: 1024,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          Logger.debug(output: output)
          {:ok, output}

        {output, code} ->
          Logger.error(msg: "Activation failed", output: output, return_code: code)
          {:error, code, output}
      end
    else
      nil ->
        Logger.error("Required executables not found: sudo and/or sower-activator")
        {:error, :cmd_not_found}
    end
  end

  @doc """
  Check if activator socket exists and is connectable.

  Returns `true` if socket file exists, `false` otherwise.
  """
  def socket_available?(socket_path \\ @default_socket_path) do
    File.exists?(socket_path)
  end

  # Private functions - Socket communication

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
        "type" => request.type,
        "path" => request.path
      }
      |> maybe_put("mode", request.mode)

    Jason.encode!(map)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp receive_responses(socket, request_id, on_output) do
    receive_loop(socket, request_id, on_output, [])
  end

  defp receive_loop(socket, request_id, on_output, acc) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, line} ->
        case parse_response(line) do
          {:ok, %Response{id: ^request_id} = response} ->
            handle_response(socket, response, on_output, acc)

          {:ok, %Response{id: other_id}} ->
            Logger.warning(
              msg: "Received response for wrong request",
              expected: request_id,
              got: other_id
            )

            receive_loop(socket, request_id, on_output, acc)

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

  defp handle_response(socket, %Response{type: "output"} = response, on_output, acc) do
    on_output.(response.data)
    receive_loop(socket, response.id, on_output, [response.data | acc])
  end

  defp handle_response(socket, %Response{type: "error"} = response, on_output, acc) do
    on_output.(response.data)
    receive_loop(socket, response.id, on_output, [response.data | acc])
  end

  defp handle_response(_socket, %Response{type: "complete"} = response, _on_output, acc) do
    output = Enum.reverse(acc)

    case response.exit_code do
      0 -> {:ok, output}
      code -> {:error, code, output}
    end
  end

  defp handle_response(socket, %Response{} = response, on_output, acc) do
    Logger.warning(msg: "Unknown response type", type: response.type)
    receive_loop(socket, response.id, on_output, acc)
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
        {:error, :missing_required_fields}

      {:error, reason} ->
        {:error, {:json_decode_failed, reason}}
    end
  end

  defp generate_request_id do
    SowerClient.Sid.generate("act")
  end

  # Private functions - CLI invocation

  defp build_cli_args(type, path, opts) do
    args = ["-path", path, "-type", type]

    case Keyword.get(opts, :mode) do
      nil -> args
      mode -> args ++ ["-mode", mode]
    end
  end
end
