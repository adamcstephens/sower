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
         cmdline: metadata["cmdline"]
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp supported(%{"contract" => contract}) when contract != 1,
    do: {:error, {:unsupported_contract, contract}}

  defp supported(%{"system" => system}) when system != "x86_64-linux",
    do: {:error, {:unsupported_system, system}}

  defp supported(%{"version" => version}) when version != 1,
    do: {:error, {:unsupported_metadata_version, version}}

  defp supported(%{
         "version" => 1,
         "system" => "x86_64-linux",
         "contract" => 1,
         "vsock_port" => 5000,
         "scratch" => %{
           "device" => "/dev/vdb",
           "label" => "sower-scratch",
           "filesystem" => "ext4"
         },
         "cmdline" => cmdline
       })
       when is_binary(cmdline), do: :ok

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
