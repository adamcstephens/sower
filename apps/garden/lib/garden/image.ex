defmodule Garden.Image do
  @moduledoc """
  Local no-NIC command execution in an image produced by mkImage.

  Load metadata with `load/1`, then start a caller-supervised execution with
  `start_link(image: image, command: %Command{}, ...)`. `status/1` remains
  inspectable; `await/1` waits for certified teardown. `cancel/1` initiates
  independent teardown. `run/3` is the synchronous convenience boundary.
  `on_output` receives `(stream, bytes)` in the I/O worker, applying bounded
  backpressure without blocking cancellation or the execution deadline.
  This is development orchestration, not a production sandbox.
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

  typedstruct module: Command do
    field :path, String.t(), enforce: true
    field :args, [String.t()], default: []
    field :env, map(), default: %{}
    field :stdin, term(), default: %{}
  end

  typedstruct module: Result do
    field :code, integer() | nil
    field :signal, integer() | nil
    field :ready_ms, non_neg_integer()
    field :elapsed_ms, non_neg_integer()
  end

  typedstruct module: Status do
    field :phase, atom(), default: :starting
    field :directory, String.t()
    field :vmm, pid()
    field :os_pid, pos_integer()
    field :result, term()
    field :cleanup, term()
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

  def start_link(options), do: Garden.Image.Execution.start_link(options)
  def child_spec(options), do: Garden.Image.Execution.child_spec(options)
  def status(server), do: GenServer.call(server, :status)
  def await(server), do: GenServer.call(server, :await, :infinity)
  def cancel(server), do: GenServer.call(server, :cancel)

  def run(%__MODULE__{} = image, %Command{} = command, options \\ []) do
    with {:ok, server} <- start_link(Keyword.merge(options, image: image, command: command)) do
      try do
        await(server)
      after
        GenServer.stop(server)
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_command(%Command{} = command) do
    cond do
      not is_binary(command.path) or not String.starts_with?(command.path, "/") ->
        {:error, :invalid_command_path}

      not is_list(command.args) or not Enum.all?(command.args, &is_binary/1) ->
        {:error, :invalid_command_args}

      not is_map(command.env) or
          not Enum.all?(command.env, fn {k, v} ->
            is_binary(k) and is_binary(v) and k != "" and not String.contains?(k, ["=", <<0>>]) and
                not String.contains?(v, <<0>>)
          end) ->
        {:error, :invalid_command_env}

      String.contains?(command.path, <<0>>) or
          Enum.any?(command.args, &String.contains?(&1, <<0>>)) ->
        {:error, :invalid_command_argument}

      true ->
        :ok
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
