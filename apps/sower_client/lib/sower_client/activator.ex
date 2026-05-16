defmodule SowerClient.Activator do
  @moduledoc """
  Activate Nix configurations (NixOS, home-manager) via `sower activator`.

  Two transports speak the same JSON-over-stdio protocol:

  - **Socket mode**: connect to the systemd-activated daemon over a Unix
    domain socket.
  - **Port mode**: spawn `sower activator` as a subprocess via an Erlang Port
    (`{:spawn_executable, ...}`). Used as a fallback when the socket isn't
    available, and as the only path for self-managed home-manager
    activations where the current user matches the `username` tag.

  ## Activation Path Selection

  The `activate/3` function selects the transport based on type and context:

  1. For **home-manager** with username tag matching the current user:
     Uses Port activation directly (no sudo, no socket).
  2. For **NixOS** or other types:
     Uses socket activation when available, falls back to Port with sudo.
  3. For **home-manager** with mismatched username:
     Uses socket activation when available, otherwise returns
     `{:error, :username_mismatch}`.
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
  Activate a configuration via socket or Port fallback.

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
    tags = Keyword.get(opts, :tags, [])

    if type == "home-manager" and username_matches_current_user?(tags) do
      Logger.debug("Home-manager username matches current user, using direct Port activation")
      activate_via_port(type, path, opts)
    else
      if socket_available?(socket_path) do
        activate_via_socket(type, path, opts)
      else
        Logger.debug("Socket not available, falling back to Port activation")
        activate_via_port(type, path, opts)
      end
    end
  end

  @doc """
  Request a system reboot via socket or Port fallback.

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
      Logger.debug("Socket not available, falling back to Port reboot")
      reboot_via_port(opts)
    end
  end

  @doc """
  Activate via Unix socket connection to the sower activator daemon.
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
  Request reboot via Unix socket connection to the sower activator daemon.
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
  Activate via an Erlang Port speaking JSON-over-stdio with `sower activator`.

  For home-manager seeds with a matching username tag, runs the activator
  directly as the current user (no sudo). Otherwise runs under `sudo`.

  ## Returns

  - `{:ok, output_lines}` - Success
  - `{:error, :cmd_not_found}` - Required executables not found
  - `{:error, :missing_username_tag}` - Home-manager seed missing username tag
  - `{:error, :username_mismatch}` - Home-manager username doesn't match current user
  - `{:error, exit_code, output}` - Activation failed
  """
  def activate_via_port(type, path, opts \\ []) do
    mode = Keyword.get(opts, :mode)
    tags = Keyword.get(opts, :tags, [])
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)

    request = %Request{
      id: generate_request_id(),
      type: type,
      path: path,
      mode: mode
    }

    with :ok <- validate_privileges(type, tags),
         {:ok, executable, args} <- build_port_command(type, tags) do
      run_via_port(executable, args, request, on_output)
    else
      {:error, _} = error -> error
    end
  end

  @doc """
  Request reboot via an Erlang Port speaking JSON-over-stdio with `sower activator`.
  """
  def reboot_via_port(opts \\ []) do
    reason = Keyword.get(opts, :reason)
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)

    request = %Request{
      id: generate_request_id(),
      type: "reboot",
      reason: reason
    }

    case build_port_command_privileged() do
      {:ok, executable, args} -> run_via_port(executable, args, request, on_output)
      {:error, _} = error -> error
    end
  end

  @doc """
  Check if activator socket exists.
  """
  def socket_available?(socket_path \\ @default_socket_path) do
    File.exists?(socket_path)
  end

  @doc """
  Check if the username tag matches the current user.
  """
  def username_matches_current_user?(tags) when is_list(tags) do
    current_user = System.get_env("USER")

    case Enum.find(tags, &(&1.key == "username")) do
      %{value: ^current_user} -> true
      _ -> false
    end
  end

  def username_matches_current_user?(_tags), do: false

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
          reason: inspect(reason),
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
        Logger.error(msg: "Failed to send request to activator", reason: inspect(reason))
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
            Logger.error(msg: "Failed to parse response", reason: inspect(reason), line: line)
            {:error, {:parse_failed, reason}}
        end

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, :closed} ->
        {:error, :connection_closed}

      {:error, reason} ->
        Logger.error(msg: "Failed to receive from activator", reason: inspect(reason))
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

  # Private functions - Port (subprocess) communication

  defp validate_privileges("home-manager", tags) do
    current_user = System.get_env("USER")

    case Enum.find(tags, &(&1.key == "username")) do
      nil -> {:error, :missing_username_tag}
      %{value: ^current_user} -> :ok
      _other -> {:error, :username_mismatch}
    end
  end

  defp validate_privileges(_type, _tags), do: :ok

  defp build_port_command("home-manager", tags) do
    current_user = System.get_env("USER")

    case Enum.find(tags, &(&1.key == "username")) do
      %{value: ^current_user} -> build_port_command_direct()
      _ -> {:error, :username_mismatch}
    end
  end

  defp build_port_command(_type, _tags), do: build_port_command_privileged()

  defp build_port_command_direct do
    case System.find_executable("sower-activator") do
      nil ->
        Logger.error("Required executable not found: sower-activator")
        {:error, :cmd_not_found}

      activator ->
        {:ok, activator, []}
    end
  end

  defp build_port_command_privileged do
    with activator when not is_nil(activator) <- System.find_executable("sower-activator"),
         sudo when not is_nil(sudo) <- System.find_executable("sudo") do
      {:ok, sudo, [activator]}
    else
      nil ->
        Logger.error("Required executables not found: sudo and/or sower-activator")
        {:error, :cmd_not_found}
    end
  end

  defp run_via_port(executable, args, %Request{} = request, on_output) do
    port =
      Port.open(
        {:spawn_executable, executable},
        [:binary, :exit_status, :hide, {:args, args}]
      )

    payload = [encode_request(request), "\n"]
    Port.command(port, payload)

    port_receive_loop(port, request.id, on_output, "", [])
  end

  defp port_receive_loop(port, request_id, on_output, buffer, acc) do
    receive do
      {^port, {:data, data}} ->
        {lines, rest} = split_lines(buffer <> data)

        case process_port_lines(lines, request_id, on_output, acc) do
          {:complete, result} ->
            drain_port(port)
            result

          {:continue, new_acc} ->
            port_receive_loop(port, request_id, on_output, rest, new_acc)
        end

      {^port, {:exit_status, status}} ->
        Logger.error(
          msg: "Activator port exited without complete response",
          exit_status: to_string(status)
        )

        {:error, {:port_exited, status}, Enum.reverse(acc)}
    after
      @recv_timeout ->
        Logger.error(msg: "Timeout waiting for activator port response")
        drain_port(port)
        {:error, :timeout}
    end
  end

  defp split_lines(binary) do
    parts = :binary.split(binary, "\n", [:global])
    {Enum.drop(parts, -1), List.last(parts) || ""}
  end

  defp process_port_lines([], _request_id, _on_output, acc), do: {:continue, acc}

  defp process_port_lines([line | rest], request_id, on_output, acc) do
    case process_port_line(line, request_id, on_output, acc) do
      {:complete, result} -> {:complete, result}
      {:continue, new_acc} -> process_port_lines(rest, request_id, on_output, new_acc)
    end
  end

  defp process_port_line("", _request_id, _on_output, acc), do: {:continue, acc}

  defp process_port_line(line, request_id, on_output, acc) do
    case parse_response(line) do
      {:ok, %Response{id: ^request_id, type: "output"} = resp} ->
        on_output.(resp.data)
        {:continue, [resp.data | acc]}

      {:ok, %Response{id: ^request_id, type: "error"} = resp} ->
        on_output.(resp.data)
        {:continue, [resp.data | acc]}

      {:ok, %Response{id: ^request_id, type: "complete", exit_code: code}} ->
        output = Enum.reverse(acc)
        result = if code == 0, do: {:ok, output}, else: {:error, code, output}
        {:complete, result}

      {:ok, %Response{id: other_id}} ->
        Logger.warning(
          msg: "Received response for wrong request",
          expected: request_id,
          got: other_id
        )

        {:continue, acc}

      {:error, reason} ->
        Logger.error(msg: "Failed to parse activator line", reason: inspect(reason), line: line)
        {:continue, acc}
    end
  end

  defp drain_port(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    end

    flush_port(port)
  end

  defp flush_port(port) do
    receive do
      {^port, _} -> flush_port(port)
    after
      0 -> :ok
    end
  end
end
