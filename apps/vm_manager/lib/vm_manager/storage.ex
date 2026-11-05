defmodule VMManager.Storage do
  @moduledoc false
  use TypedStruct
  alias CloudHypervisor.Config.Disk
  alias VMManager.Config

  typedstruct module: EphemeralDisk do
    field :name, String.t(), enforce: true
    field :bytes, pos_integer(), enforce: true
    field :filesystem, :ext4 | nil
    field :label, String.t()
  end

  def valid?(%Config{disks: disks, persistent_disks: persistent} = config)
      when is_list(disks) and is_list(persistent) do
    names = for %EphemeralDisk{name: name} <- config.disks, do: name
    paths = for %Disk{path: path} <- config.disks, do: path

    Enum.all?(config.disks, fn
      %Disk{} = disk ->
        is_binary(disk.path)

      %EphemeralDisk{} = disk ->
        is_binary(disk.name) and disk.name not in ["", ".", "..", "serial.log"] and
          Path.basename(disk.name) == disk.name and not String.contains?(disk.name, ["/", "\\"]) and
          is_integer(disk.bytes) and disk.bytes > 0 and disk.filesystem in [nil, :ext4] and
          (is_nil(disk.label) or is_binary(disk.label))

      _ ->
        false
    end) and length(names) == length(Enum.uniq(names)) and
      Enum.all?(config.persistent_disks, &(&1 in paths))
  end

  def valid?(%Config{}), do: false

  def valid_output_file?(file) when is_binary(file) do
    not String.contains?(file, <<0>>) and
      (Path.type(file) == :absolute or
         (file not in ["", ".", ".."] and Path.basename(file) == file and
            not String.contains?(file, ["/", "\\"])))
  end

  def valid_output_file?(_file), do: false

  def resources(%Config{} = config) do
    bytes =
      Enum.reduce(config.disks, 0, fn
        %EphemeralDisk{} = disk, total -> total + disk.bytes
        %Disk{}, total -> total
      end)

    [vms: 1, cpus: config.cpus, memory: config.memory, scratch_bytes: bytes]
  end

  def prepare(%Config{} = config, directory) do
    if valid?(config) and distinct_paths?(config, directory) do
      Enum.reduce_while(config.disks, {:ok, []}, fn
        %Disk{}, result ->
          {:cont, result}

        %EphemeralDisk{} = disk, {:ok, commands} ->
          path = Path.join(directory, disk.name)

          case create(path, disk.bytes) do
            :ok ->
              command =
                if disk.filesystem == :ext4 do
                  [config.mkfs, "-q", "-F"] ++
                    if(disk.label, do: ["-L", disk.label], else: []) ++ [path]
                end

              {:cont, {:ok, commands ++ if(command, do: [command], else: [])}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end)
    else
      {:error, :invalid_storage}
    end
  end

  defp create(path, bytes) do
    case :file.open(String.to_charlist(path), [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        result =
          with {:ok, _} <- :file.position(file, bytes),
               :ok <- :file.truncate(file) do
            :ok
          else
            {:error, reason} -> {:error, reason}
          end

        :ok = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  def cleanup(%Config{}, nil), do: :ok

  def cleanup(%Config{} = config, directory) do
    names = for %EphemeralDisk{name: name} <- config.disks, do: name

    outputs =
      for %CloudHypervisor.Config.Output{mode: :file, file: file} <-
            [config.serial, config.console],
          valid_output_file?(file),
          Path.type(file) == :relative,
          do: file

    names = names ++ outputs

    with true <- valid?(config) and distinct_paths?(config, directory),
         {:ok, %{type: :directory}} <- File.lstat(directory),
         {:ok, files} <- File.ls(directory),
         [] <- files -- names,
         true <-
           Enum.all?(files, fn name ->
             case File.lstat(Path.join(directory, name)) do
               {:ok, %{type: :regular}} -> true
               _ -> false
             end
           end) do
      Enum.reduce_while(files, :ok, fn name, :ok ->
        case File.rm(Path.join(directory, name)) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> File.rmdir(directory)
        error -> error
      end
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unowned_storage}
    end
  end

  def distinct_paths?(%Config{} = config, directory \\ nil) do
    outputs =
      for %CloudHypervisor.Config.Output{mode: :file, file: file} <-
            [config.serial, config.console],
          do: file

    if Enum.all?(outputs, &valid_output_file?/1) do
      paths =
        Enum.map(config.disks, fn
          %Disk{} = disk -> Path.expand(disk.path)
          %EphemeralDisk{} = disk -> owned_path(disk.name, directory)
        end) ++
          Enum.map(outputs, fn file ->
            if Path.type(file) == :absolute,
              do: Path.expand(file),
              else: owned_path(file, directory)
          end)

      length(paths) == length(Enum.uniq(paths))
    else
      false
    end
  end

  defp owned_path(name, nil), do: {:runtime, name}
  defp owned_path(name, directory), do: Path.expand(name, directory)
end
