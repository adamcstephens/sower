defmodule VMManager.Machine do
  @moduledoc """
  Translates VM manager configuration into Cloud Hypervisor configuration.

  It resolves attempt-local disk and output paths and compares an attached
  VMM's reported configuration and state against the expected machine.
  """
  alias CloudHypervisor.Config, as: Native
  alias VMManager.Config
  alias VMManager.Storage.EphemeralDisk

  def build(%Config{} = config, directory, network) do
    %Native{
      kernel: config.kernel,
      initramfs: config.initrd,
      cmdline:
        config.cmdline <> " sower.vm.id=#{config.id}" <> VMManager.Network.cmdline(network),
      cpus: %Native.CPUs{boot_vcpus: config.cpus, max_vcpus: config.cpus},
      memory: config.memory,
      disks:
        Enum.map(config.disks, fn
          %Native.Disk{} = disk ->
            disk

          %EphemeralDisk{} = disk ->
            %Native.Disk{path: Path.join(directory, disk.name), readonly: false, image_type: :raw}
        end),
      net: VMManager.Network.devices(network),
      serial: output(config.serial, directory),
      console: output(config.console, directory),
      rng: config.rng,
      vsock: config.vsock
    }
  end

  def matches?(%CloudHypervisor.API.Info{} = info, %Config{} = config, directory, network) do
    expected = build(config, directory, network) |> Native.to_api()
    actual = info.config

    (info.state == "Running" or (info.state == "Created" and info.device_tree == nil)) and
      subset?(expected, actual) and
      get_in(actual, ["payload", "initramfs"]) == config.initrd and
      subset?(Map.get(expected, "disks", []), Map.get(actual, "disks", [])) and
      subset?(Map.get(expected, "net", []), Map.get(actual, "net", [])) and
      (config.vsock != nil or Map.get(actual, "vsock") == nil)
  end

  defp subset?(expected, actual) when is_map(expected) and is_map(actual),
    do: Enum.all?(expected, fn {key, value} -> subset?(value, Map.get(actual, key)) end)

  defp subset?(expected, actual) when is_list(expected) and is_list(actual),
    do:
      length(expected) == length(actual) and
        Enum.all?(Enum.zip(expected, actual), fn {left, right} -> subset?(left, right) end)

  defp subset?(expected, actual), do: expected == actual

  defp output(nil, _directory), do: nil

  defp output(%Native.Output{mode: :file} = output, directory) do
    if Path.type(output.file) == :absolute,
      do: output,
      else: %{output | file: Path.expand(output.file, directory)}
  end

  defp output(%Native.Output{} = output, _directory), do: output
end
