defmodule Garden.Image.Guard do
  @moduledoc false
  use TypedStruct
  alias CloudHypervisor.{Config, Launch}

  typedstruct do
    field :server, pid(), enforce: true
    field :server_monitor, reference(), enforce: true
    field :owner_monitor, reference(), enforce: true
    field :directory, String.t()
    field :vmm, pid()
    field :formatter, pid()
    field :io, pid()
    field :outcome, term()
    field :cleanup_error, term()
    field :started, integer(), enforce: true
    field :options, keyword(), enforce: true
  end

  def run(server, options) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      server: server,
      server_monitor: Process.monitor(server),
      owner_monitor: Process.monitor(options[:owner]),
      options: options,
      started: System.monotonic_time(:millisecond)
    }

    Process.send_after(self(), :deadline, Keyword.get(options, :deadline_ms, 60_000))

    directory =
      Path.join(
        Keyword.get(options, :resource_directory, System.tmp_dir!()),
        "sower-image-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    case File.mkdir(directory) do
      :ok ->
        prepare(%{state | directory: directory})

      {:error, reason} ->
        send(server, {:image_finished, {:error, {:resource_directory, reason}}, :ok})
    end
  end

  defp prepare(%__MODULE__{} = state) do
    directory = state.directory
    options = state.options
    send(state.server, {:image_status, [directory: directory]})

    with :ok <- File.chmod(directory, 0o700),
         :ok <-
           sparse(
             Path.join(directory, "scratch.ext4"),
             Keyword.get(options, :scratch_bytes, 4 * 1024 * 1024 * 1024)
           ) do
      start_formatter(state)
    else
      {:error, reason} -> finish(state, {:error, {:scratch_startup, reason}}, :ok)
    end
  end

  defp start_formatter(%__MODULE__{} = state) do
    case Rexec.run_link(
           [
             Keyword.get(state.options, :mkfs, "mkfs.ext4"),
             "-q",
             "-F",
             "-L",
             "sower-scratch",
             Path.join(state.directory, "scratch.ext4")
           ],
           owner: self()
         ) do
      {:ok, formatter, _os_pid} -> loop(%{state | formatter: formatter})
      {:error, reason} -> finish(state, {:error, {:scratch_startup, reason}}, :unconfirmed)
    end
  end

  defp sparse(path, size) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:write, :binary, :exclusive]) do
      result =
        with {:ok, _} <- :file.position(file, size - 1),
             :ok <- :file.write(file, <<0>>) do
          :ok
        else
          {:error, reason} -> {:error, reason}
        end

      :file.close(file)
      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp loop(%__MODULE__{} = state) do
    receive do
      {:EXIT, formatter, reason} when formatter == state.formatter ->
        case CloudHypervisor.Cleanup.completion(reason) do
          {:ok, {:exit_status, 0}} when state.cleanup_error == nil ->
            if state.outcome,
              do: finish(state, state.outcome, :ok),
              else: launch(%{state | formatter: nil})

          {:ok, _} when state.cleanup_error == nil ->
            finish(state, state.outcome || {:error, {:mkfs, reason}}, :ok)

          error ->
            finish(
              state,
              state.outcome || {:error, {:mkfs, reason}},
              state.cleanup_error || error
            )
        end

      {:cleanup_error, _pid, message} ->
        loop(%{state | cleanup_error: message})

      {:finish, result} ->
        stop(state, result)

      :deadline ->
        stop(state, {:error, :timeout})

      :cleanup_deadline ->
        finish(state, state.outcome, :shutdown_timeout)

      {:DOWN, ref, :process, _pid, _reason}
      when ref == state.server_monitor or ref == state.owner_monitor ->
        stop(state, {:error, :owner_down})

      {:DOWN, _ref, :process, io, reason} when io == state.io ->
        stop(state, {:error, {:io_down, reason}})

      {:guest_ready, _ready} ->
        send(state.server, {:image_status, [phase: :running]})
        loop(state)

      {:cloud_hypervisor, vmm, {:exited, outcome}} when vmm == state.vmm ->
        stop(state, {:error, {:vmm_exited, outcome}})

      {:cloud_hypervisor, vmm, {:failed, reason}} when vmm == state.vmm ->
        stop(state, {:error, {:vmm_failed, reason}})

      {:EXIT, vmm, reason} when vmm == state.vmm ->
        finish(state, {:error, {:vmm_server_down, reason}}, :unconfirmed)

      _ ->
        loop(state)
    end
  end

  defp launch(%__MODULE__{} = state) do
    image = state.options[:image]
    cpus = Keyword.get(state.options, :cpus, 1)

    config = %Config{
      kernel: image.kernel,
      initramfs: image.initrd,
      cmdline: image.cmdline,
      cpus: %Config.CPUs{boot_vcpus: cpus, max_vcpus: cpus},
      memory: Keyword.get(state.options, :memory, 512 * 1024 * 1024),
      disks: [
        %Config.Disk{path: image.root, readonly: true, image_type: :raw},
        %Config.Disk{
          path: Path.join(state.directory, "scratch.ext4"),
          readonly: false,
          image_type: :raw
        }
      ],
      serial: %Config.Output{mode: :file, file: Path.join(state.directory, "serial.log")},
      console: %Config.Output{mode: :off},
      rng: %Config.RNG{src: "/dev/urandom"},
      vsock: %Config.Vsock{cid: 3, socket: nil}
    }

    case CloudHypervisor.Process.start_link(
           config: config,
           owner: self(),
           launch: %Launch{
             executable: Keyword.get(state.options, :hypervisor, "cloud-hypervisor")
           },
           readiness_timeout: Keyword.get(state.options, :deadline_ms, 60_000)
         ) do
      {:ok, vmm} ->
        status = CloudHypervisor.Process.status(vmm)
        send(state.server, {:image_status, [vmm: vmm, os_pid: status.os_pid]})
        guard = self()

        {io, _monitor} =
          spawn_monitor(fn ->
            Garden.Image.IO.run(
              guard,
              vmm,
              state.options[:command],
              Keyword.get(state.options, :on_output, &Garden.Image.IO.output/2),
              state.started
            )
          end)

        loop(%{state | vmm: vmm, io: io})

      {:error, reason} ->
        finish(state, {:error, {:vmm_startup, reason}}, :unconfirmed)
    end
  end

  defp stop(%__MODULE__{outcome: outcome} = state, _result) when not is_nil(outcome),
    do: loop(state)

  defp stop(%__MODULE__{formatter: formatter} = state, result) when not is_nil(formatter) do
    try do
      Rexec.kill_tree(formatter, :sigkill)
    catch
      :exit, _reason -> :ok
    end

    Process.send_after(self(), :cleanup_deadline, 10_000)
    loop(%{state | outcome: result})
  end

  defp stop(%__MODULE__{vmm: nil} = state, result), do: finish(state, result, :ok)

  defp stop(%__MODULE__{} = state, result) do
    if state.io, do: Process.exit(state.io, :kill)
    guard = self()
    vmm = state.vmm

    spawn(fn ->
      cleanup =
        try do
          case CloudHypervisor.Process.stop(vmm, :force) do
            {:error, {:startup, _message} = reason} = error ->
              case {CloudHypervisor.Process.await_ready(vmm), CloudHypervisor.Process.status(vmm)} do
                {{:error, ^reason},
                 %CloudHypervisor.Process.Status{
                   phase: :failed,
                   error: ^reason,
                   os_pid: nil,
                   outcome: nil
                 }} ->
                  :startup_cleanup_confirmed

                _ ->
                  error
              end

            result ->
              result
          end
        catch
          :exit, reason -> {:error, {:vmm_stop, reason}}
        end

      send(guard, {:stopped, cleanup})
    end)

    Process.send_after(self(), :cleanup_deadline, 10_000)
    await_stop(%{state | outcome: result})
  end

  defp await_stop(%__MODULE__{} = state) do
    receive do
      {:stopped, {:ok, _}} ->
        GenServer.stop(state.vmm, :normal)
        finish(state, state.outcome, :ok)

      {:stopped, :startup_cleanup_confirmed} ->
        GenServer.stop(state.vmm, :normal)
        finish(state, state.outcome, :ok)

      {:stopped, error} ->
        finish(state, state.outcome, error)

      :cleanup_deadline ->
        finish(state, state.outcome, :shutdown_timeout)

      _ ->
        await_stop(state)
    end
  end

  defp finish(%__MODULE__{} = state, result, certification) do
    if state.io, do: Process.exit(state.io, :kill)
    cleanup = if certification == :ok, do: remove_known(state.directory), else: certification

    result =
      if cleanup == :ok,
        do: result,
        else: {:error, {:cleanup_unconfirmed, result, cleanup, state.directory}}

    send(state.server, {:image_finished, result, cleanup})
  end

  defp remove_known(directory) do
    with {:ok, files} <- File.ls(directory),
         [] <- files -- ["scratch.ext4", "serial.log"],
         :ok <-
           Enum.reduce_while(files, :ok, fn file, :ok ->
             case File.rm(Path.join(directory, file)) do
               :ok -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end),
         :ok <- File.rmdir(directory) do
      :ok
    else
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
      unexpected -> {:error, {:unexpected_files, unexpected}}
    end
  end
end
