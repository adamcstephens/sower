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
    field(:path, String.t())
    field(:mode, String.t())
    field(:reason, String.t())
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
  - `:tags` - Seed tags for privilege checking (home-manager seeds with username tag)

  ## Returns

  - `{:ok, output_lines}` - Success with output lines as strings
  - `{:error, reason}` - Connection/socket error
  - `{:error, exit_code, output}` - Activation failed with exit code
  - `{:error, :missing_username_tag}` - Home-manager seed missing username tag
  - `{:error, :username_mismatch}` - Home-manager username doesn't match current user
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
  Request a system reboot via socket or CLI fallback.

  ## Options

  - `:socket_path` - Path to activator socket (default: #{@default_socket_path})
  - `:reason` - Optional reason attached to reboot request
  - `:on_output` - Callback function for streaming output
  """
  def reboot(opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)

    if socket_available?(socket_path) do
      reboot_via_socket(opts)
    else
      Logger.debug("Socket not available, falling back to CLI reboot")
      reboot_via_cli(opts)
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
  Request reboot via Unix socket connection to sower-activator daemon.
  """
  def reboot_via_socket(opts \\ []) do
    socket_path = Keyword.get(opts, :socket_path, @default_socket_path)
    reason = Keyword.get(opts, :reason)
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)

    request = %Request{
      id: generate_request_id(),
      type: "reboot",
      reason: reason
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

  For home-manager seeds with a matching username tag, activates without sudo.
  For nixos seeds or mismatched usernames, requires `sudo` and `sower-activator`.

  ## Options

  - `:mode` - Activation mode
  - `:tags` - Seed tags for privilege checking (home-manager seeds with username tag)

  ## Returns

  - `{:ok, output_lines}` - Success
  - `{:error, :cmd_not_found}` - Required executables not found
  - `{:error, :missing_username_tag}` - Home-manager seed missing username tag
  - `{:error, :username_mismatch}` - Home-manager username doesn't match current user
  - `{:error, exit_code, output}` - Command failed
  """
  def activate_via_cli(type, path, opts \\ []) do
    args = build_cli_args(type, path, opts)
    tags = Keyword.get(opts, :tags, [])

    with :ok <- validate_privileges(type, tags),
         {:ok, cmd, cmd_args} <- build_cli_command(args, type, tags),
         {:ok, output} <- run_cli_command(cmd, cmd_args) do
      {:ok, output}
    end
  end

  @doc """
  Request reboot via CLI invocation of `systemctl reboot`.
  """
  def reboot_via_cli(_opts \\ []) do
    with systemctl when not is_nil(systemctl) <- System.find_executable("systemctl"),
         sudo when not is_nil(sudo) <- System.find_executable("sudo") do
      case System.cmd(sudo, [systemctl, "reboot"],
             into: [],
             lines: 1024,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          Logger.debug(output: output)
          {:ok, output}

        {output, code} ->
          Logger.error(msg: "Reboot failed", output: output, return_code: code)
          {:error, code, output}
      end
    else
      nil ->
        Logger.error("Required executables not found: sudo and/or systemctl")
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
        "type" => request.type
      }
      |> maybe_put("path", request.path)
      |> maybe_put("mode", request.mode)
      |> maybe_put("reason", request.reason)

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

  defp validate_privileges("home-manager", tags) do
    current_user = System.get_env("USER")

    case Enum.find(tags, &(&1.key == "username")) do
      nil ->
        {:error, :missing_username_tag}

      %{value: ^current_user} ->
        :ok

      _other ->
        {:error, :username_mismatch}
    end
  end

  defp validate_privileges(_type, _tags), do: :ok

  defp build_cli_command(args, "home-manager", tags) do
    current_user = System.get_env("USER")

    case Enum.find(tags, &(&1.key == "username")) do
      %{value: ^current_user} ->
        # No sudo needed when username matches
        with activator when not is_nil(activator) <- System.find_executable("sower-activator") do
          {:ok, activator, args}
        else
          nil ->
            Logger.error("Required executable not found: sower-activator")
            {:error, :cmd_not_found}
        end

      _ ->
        # This shouldn't happen if validate_privileges was called first
        {:error, :username_mismatch}
    end
  end

  defp build_cli_command(args, _type, _tags) do
    with activator when not is_nil(activator) <- System.find_executable("sower-activator"),
         sudo when not is_nil(sudo) <- System.find_executable("sudo") do
      {:ok, sudo, [activator | args]}
    else
      nil ->
        Logger.error("Required executables not found: sudo and/or sower-activator")
        {:error, :cmd_not_found}
    end
  end

  defp run_cli_command({:error, reason}, _args), do: {:error, reason}

  defp run_cli_command(cmd, args) do
    case System.cmd(cmd, args,
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
  end
end
