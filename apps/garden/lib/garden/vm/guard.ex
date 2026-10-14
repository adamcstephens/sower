defmodule Garden.VM.Guard do
  @moduledoc false
  use TypedStruct
  alias CloudHypervisor.{Config, Launch}

  typedstruct do
    field :server, pid(), enforce: true
    field :server_monitor, reference(), enforce: true
    field :owner_monitor, reference(), enforce: true
    field :ledger_monitor, reference()
    field :directory, String.t()
    field :vmm, pid()
    field :formatter, pid()
    field :io, pid()
    field :network, Garden.VM.Network.t()
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

    state =
      if options[:ledger] do
        ledger = GenServer.whereis(options[:ledger])
        %{state | ledger_monitor: Process.monitor(ledger || self())}
      else
        state
      end

    registration = register(state)

    if registration != :ok do
      finish(state, {:error, :owner_down}, :ok)
    else
      allocate(state)
    end
  end

  defp allocate(%__MODULE__{} = state) do
    options = state.options
    Process.send_after(self(), :deadline, Keyword.get(options, :deadline_ms, 60_000))

    directory =
      Path.join(
        Keyword.get(options, :resource_directory, System.tmp_dir!()),
        "sower-vm-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    case File.mkdir(directory) do
      :ok ->
        prepare(%{state | directory: directory})

      {:error, reason} ->
        finish(state, {:error, {:resource_directory, reason}}, :ok)
    end
  end

  defp prepare(%__MODULE__{} = state) do
    directory = state.directory
    options = state.options
    notify_status(state, directory: directory)

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
      when ref == state.server_monitor or ref == state.owner_monitor or
             ref == state.ledger_monitor ->
        stop(state, {:error, :owner_down})

      {:DOWN, _ref, :process, io, reason} when io == state.io ->
        stop(state, {:error, {:io_down, reason}})

      {:guest_ready, _ready} ->
        notify_status(state, phase: :running)
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
    case Garden.VM.Network.provision(state.options) do
      {:ok, network} ->
        admit_launch(%{state | network: network})

      {:error, {:network_provision_unconfirmed, _} = reason} ->
        finish(state, {:error, reason}, :unconfirmed)

      {:error, reason} ->
        finish(state, {:error, reason}, :ok)
    end
  end

  defp admit_launch(%__MODULE__{} = state) do
    receive do
      {:finish, result} ->
        stop(state, result)

      :deadline ->
        stop(state, {:error, :timeout})

      {:DOWN, ref, :process, _pid, _reason}
      when ref == state.server_monitor or ref == state.owner_monitor or
             ref == state.ledger_monitor ->
        stop(state, {:error, :owner_down})
    after
      0 ->
        if System.monotonic_time(:millisecond) - state.started >=
             Keyword.get(state.options, :deadline_ms, 60_000),
           do: stop(state, {:error, :timeout}),
           else: launch_vm(state)
    end
  end

  defp launch_vm(%__MODULE__{} = state) do
    image = state.options[:image]
    cpus = Keyword.get(state.options, :cpus, 1)

    config = %Config{
      kernel: image.kernel,
      initramfs: image.initrd,
      cmdline: image.cmdline <> Garden.VM.Network.cmdline(state.network),
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
      net: Garden.VM.Network.devices(state.network),
      serial: %Config.Output{mode: :file, file: Path.join(state.directory, "serial.log")},
      console: %Config.Output{mode: :off},
      rng: %Config.RNG{src: "/dev/urandom"},
      vsock: %Config.Vsock{cid: 3, socket: nil}
    }

    case CloudHypervisor.Process.start_link(
           config: config,
           owner: self(),
           before_stop: fn -> Garden.VM.Network.revoke(state.network) end,
           launch: %Launch{
             executable: Keyword.get(state.options, :hypervisor, "cloud-hypervisor")
           },
           readiness_timeout: Keyword.get(state.options, :deadline_ms, 60_000)
         ) do
      {:ok, vmm} ->
        status = CloudHypervisor.Process.status(vmm)
        notify_status(state, vmm: vmm, os_pid: status.os_pid)
        guard = self()

        {io, _monitor} =
          spawn_monitor(fn ->
            Garden.VM.IO.run(
              guard,
              vmm,
              state.options[:command],
              Keyword.get(state.options, :on_output, &Garden.VM.IO.output/2),
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
    notify_status(state, phase: :stopping)

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
    notify_status(state, phase: :stopping)
    if state.io, do: Process.exit(state.io, :kill)
    revocation = Garden.VM.Network.revoke(state.network)
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
    await_stop(%{state | outcome: result, cleanup_error: revocation_error(revocation)})
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

    network_cleanup =
      case Garden.VM.Network.revoke(state.network) do
        :ok when certification == :ok -> Garden.VM.Network.release(state.network)
        result -> result
      end

    cleanup =
      cond do
        certification != :ok -> certification
        state.cleanup_error != nil -> state.cleanup_error
        network_cleanup != :ok -> network_cleanup
        true -> remove_known(state.directory)
      end

    result =
      if cleanup == :ok,
        do: result,
        else: {:error, {:cleanup_unconfirmed, result, cleanup, state.directory}}

    if state.options[:ledger] do
      id = state.options[:execution_id]

      :ets.insert(
        state.options[:ledger_table],
        {{:terminal, id}, self(), result, cleanup, state.directory}
      )

      try do
        GenServer.call(
          state.options[:ledger],
          {:finished, id, self(), result, cleanup},
          :infinity
        )
      catch
        :exit, _reason -> :ok
      end
    end

    send(state.server, {:vm_finished, result, cleanup})
  end

  defp revocation_error(:ok), do: nil
  defp revocation_error(error), do: error

  defp register(%__MODULE__{} = state) do
    if state.options[:ledger] do
      id = state.options[:execution_id]
      :ets.insert(state.options[:ledger_table], {{:guard, id}, self()})

      try do
        GenServer.call(state.options[:ledger], {:guard_started, id, self()}, :infinity)
      catch
        :exit, _reason -> {:cancel, {:error, :owner_down}}
      end
    else
      :ok
    end
  end

  defp notify_status(%__MODULE__{} = state, changes) do
    send(state.server, {:vm_status, changes})

    if state.options[:ledger] do
      :ets.insert(
        state.options[:ledger_table],
        Enum.map(changes, fn {key, value} ->
          {{:status, state.options[:execution_id], key}, value}
        end)
      )

      GenServer.cast(
        state.options[:ledger],
        {:status, state.options[:execution_id], self(), changes}
      )
    end
  end

  defp remove_known(nil), do: :ok

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
