defmodule Garden.Image do
  @moduledoc """
  Boot artifacts and metadata for an image produced by mkImage.
  """
  use TypedStruct

  typedstruct do
    field :directory, String.t(), enforce: true
    field :kernel, String.t(), enforce: true
    field :initrd, String.t(), enforce: true
    field :root, String.t(), enforce: true
    field :cmdline, String.t(), enforce: true
    field :system, String.t(), default: "x86_64-linux"
    field :contract, integer(), default: 1
    field :vsock_port, integer(), default: 5000
    field :network_config, :static | nil
  end

  def load(path) do
    with {:ok, bytes} <- File.read(Path.join(path, "boot.json")),
         {:ok, metadata} <- Jason.decode(bytes),
         :ok <- supported(metadata),
         :ok <- artifacts(metadata) do
      {:ok,
       %__MODULE__{
         directory: Path.expand(path),
         kernel: metadata["kernel"],
         initrd: metadata["initrd"],
         root: metadata["root"],
         contract: metadata["contract"],
         cmdline: metadata["cmdline"],
         network_config:
           case metadata["network_config"] do
             "static" -> :static
             _ -> nil
           end
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def vm_config(%__MODULE__{} = image, id, options \\ []) do
    alias CloudHypervisor.Config, as: Native
    alias VMManager.Storage.EphemeralDisk

    {scratch_bytes, options} = Keyword.pop(options, :scratch_bytes, 4_294_967_296)
    {disks, options} = Keyword.pop(options, :disks, [])
    {network, options} = Keyword.pop(options, :network, :none)

    network =
      case network do
        :none -> nil
        :full when image.network_config == :static -> Garden.VM.Network.request()
        :full -> raise ArgumentError, "full networking requires static network image support"
        network -> network
      end

    struct!(
      VMManager.Config,
      Keyword.merge(
        [
          id: id,
          kernel: image.kernel,
          initrd: image.initrd,
          cmdline: image.cmdline,
          system: image.system,
          guest: %VMManager.Config.SowerGuest{
            contract: image.contract,
            vsock_port: image.vsock_port
          },
          disks:
            [
              %Native.Disk{path: image.root, readonly: true, image_type: :raw},
              %EphemeralDisk{
                name: "scratch.ext4",
                bytes: scratch_bytes,
                filesystem: :ext4,
                label: "sower-scratch"
              }
            ] ++ disks,
          network: network,
          serial: %Native.Output{mode: :file, file: "serial.log"},
          console: %Native.Output{mode: :off},
          rng: %Native.RNG{src: "/dev/urandom"},
          vsock: %Native.Vsock{cid: 3, socket: nil}
        ],
        options
      )
    )
  end

  defp supported(%{"contract" => contract}) when contract not in [1, 2],
    do: {:error, {:unsupported_contract, contract}}

  defp supported(%{"system" => system}) when system != "x86_64-linux",
    do: {:error, {:unsupported_system, system}}

  defp supported(%{"version" => version}) when version != 1,
    do: {:error, {:unsupported_metadata_version, version}}

  defp supported(%{
         "version" => 1,
         "system" => "x86_64-linux",
         "contract" => contract,
         "vsock_port" => 5000,
         "scratch" => %{
           "device" => "/dev/vdb",
           "label" => "sower-scratch",
           "filesystem" => "ext4"
         },
         "cmdline" => cmdline
       })
       when contract in [1, 2] and is_binary(cmdline), do: :ok

  defp supported(_), do: {:error, :invalid_boot_metadata}

  defp artifacts(metadata) do
    Enum.reduce_while(["kernel", "initrd", "root"], :ok, fn key, :ok ->
      path = metadata[key]

      if is_binary(path) and String.starts_with?(path, "/nix/store/") and File.regular?(path),
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_boot_artifact, key}}}
    end)
  end
end
