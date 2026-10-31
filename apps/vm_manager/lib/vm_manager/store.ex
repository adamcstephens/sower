defmodule VMManager.Store do
  @moduledoc false

  @durable_modules [
    VMManager.Config,
    VMManager.Manager.Definition,
    VMManager.Status,
    VMManager.Result,
    VMManager.Network,
    VMManager.Guard,
    VMManager.Execution,
    VMManager.IO,
    VMManager.Protocol,
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
    write_atomic(path, %{attempt: attempt, result: durable(result), cleanup: durable(cleanup)})
  end

  def certificate(path) do
    with {:ok, binary} <- File.read(path) do
      decode(binary)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable(value)
       when is_pid(value) or is_port(value) or is_reference(value) or is_function(value),
       do: inspect(value)

  defp durable(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&durable/1) |> List.to_tuple()

  defp durable(value) when is_list(value), do: Enum.map(value, &durable/1)

  defp durable(value) when is_map(value),
    do: Map.new(Map.to_list(value), fn {key, item} -> {durable(key), durable(item)} end)

  defp durable(value), do: value

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
