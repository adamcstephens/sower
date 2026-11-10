defmodule VMManager.Store do
  @moduledoc """
  Persists manager definitions and attempt cleanup certificates as ETF files.

  Writes use a temporary file, sync it, rename it and sync the containing
  directory. Missing definitions load as an empty map; invalid decoded values
  return an error.

  Before safe ETF decoding, `@durable_modules` are loaded so their atoms exist
  on a cold BEAM. The same list also participates in a separate write-time
  struct-preservation policy: other structs are converted to diagnostic data,
  with special handling for configuration, network and outcomes. Neither use
  makes the list a security allowlist or schema validator for decoded data.
  """

  @durable_modules [
    VMManager,
    VMManager.Config,
    VMManager.Manager,
    VMManager.Manager.Definition,
    VMManager.Status,
    VMManager.Result,
    VMManager.Network,
    VMManager.Config.SowerGuest,
    VMManager.Storage,
    VMManager.Storage.EphemeralDisk,
    VMManager.Execution,
    VMManager.Guard,
    VMManager.Guest.Session,
    VMManager.Guest.CommandExecution,
    VMManager.Guest.IO,
    VMManager.Guest.Protocol,
    CloudHypervisor.Process,
    CloudHypervisor.Cleanup,
    CloudHypervisor.API,
    CloudHypervisor.Config,
    CloudHypervisor.Config.CPUs,
    CloudHypervisor.Config.Disk,
    CloudHypervisor.Config.Net,
    CloudHypervisor.Config.Output,
    CloudHypervisor.Config.RNG,
    CloudHypervisor.Config.Vsock,
    CloudHypervisor.Config.LandlockRule
  ]

  @outcome_atoms [
    nil,
    true,
    false,
    :ok,
    :error,
    :pending,
    :unknown,
    :unconfirmed,
    :shutdown_timeout,
    :controller_lost,
    :custody_abandoned,
    :attachment_lease_consumed,
    :restart_exhausted,
    :terminated,
    :vm_failed,
    :host_restore_cleanup,
    :unowned_storage,
    :controller,
    :interrupted,
    :cancelled,
    :timeout,
    :owner_down,
    :runtime_identity_mismatch,
    :state_timeout,
    :attachment,
    :resource_directory,
    :storage_startup,
    :mkfs,
    :io_down,
    :vmm_exited,
    :vmm_failed,
    :vmm_server_down,
    :vmm_startup,
    :vmm_stop,
    :guard_down,
    :launch_failed,
    :durable_store,
    :external_shutdown,
    :cleanup_unconfirmed,
    :network_provision_unconfirmed,
    :network_checkpoint,
    :reconnect_unconfirmed,
    :econnrefused,
    :guest_protocol,
    :invalid_exit_status,
    :command_cleanup_unconfirmed
  ]

  def load(directory) do
    case File.read(Path.join(directory, "definitions.etf")) do
      {:ok, binary} -> decode(binary)
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  def save(directory, definitions),
    do: write_atomic(Path.join(directory, "definitions.etf"), durable(definitions))

  def write_certificate(path, attempt, result, cleanup) do
    write_atomic(path, %{attempt: attempt, result: outcome(result), cleanup: outcome(cleanup)})
  end

  def certificate(path) do
    with {:ok, binary} <- File.read(path) do
      decode(binary)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable(%VMManager.Config{} = value), do: value
  defp durable(%VMManager.Network{} = value), do: value

  defp durable(%CloudHypervisor.API.Error{} = value), do: diagnostic(value)

  defp durable(%module{} = value) when module not in @durable_modules,
    do: diagnostic(value)

  defp durable(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: inspect(value)

  defp durable(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&durable/1) |> List.to_tuple()

  defp durable([]), do: []
  defp durable([head | tail]), do: [durable(head) | durable(tail)]

  defp durable(value) when is_map(value) do
    Map.new(Map.to_list(value), fn
      {key, item} when key in [:result, :failure, :cleanup] -> {key, outcome(item)}
      {key, item} -> {durable(key), durable(item)}
    end)
  end

  defp durable(value), do: value

  defp outcome(value) when value in @outcome_atoms, do: value

  defp outcome(%VMManager.Config{} = value), do: value
  defp outcome(%VMManager.Network{} = value), do: value
  defp outcome(%module{} = value) when module in @durable_modules, do: durable(value)

  defp outcome(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&outcome/1) |> List.to_tuple()

  defp outcome([]), do: []
  defp outcome([head | tail]), do: [outcome(head) | outcome(tail)]

  defp outcome(value), do: diagnostic(value)

  defp diagnostic(value) when is_atom(value), do: Atom.to_string(value)

  defp diagnostic(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: inspect(value)

  defp diagnostic(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&diagnostic/1) |> List.to_tuple()

  defp diagnostic([]), do: []
  defp diagnostic([head | tail]), do: [diagnostic(head) | diagnostic(tail)]

  defp diagnostic(value) when is_map(value),
    do: Map.new(Map.to_list(value), fn {key, item} -> {diagnostic(key), diagnostic(item)} end)

  defp diagnostic(value), do: value

  defp write_atomic(path, value) do
    directory = Path.dirname(path)
    temporary = path <> ".new"

    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700),
         {:ok, file} <- :file.open(String.to_charlist(temporary), [:write, :binary, :raw]) do
      result =
        with :ok <- :file.write(file, :erlang.term_to_binary(value)),
             :ok <- :file.sync(file) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      :ok = :file.close(file)

      case result do
        :ok ->
          with :ok <- File.rename(temporary, path),
               {:ok, directory_fd} <-
                 :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
            result = :file.sync(directory_fd)
            :ok = :file.close(directory_fd)
            result
          else
            {:error, reason} -> {:error, reason}
          end

        error ->
          error
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode(binary) do
    Enum.each(@durable_modules, &Code.ensure_loaded!/1)

    try do
      case :erlang.binary_to_term(binary, [:safe]) do
        definitions when is_map(definitions) -> {:ok, definitions}
        _ -> {:error, :invalid_definitions}
      end
    rescue
      ArgumentError -> {:error, :invalid_definitions}
    end
  end
end
