defmodule Garden.VM.Guard do
  @moduledoc false
  use TypedStruct
  alias CloudHypervisor.{Config, Launch}

  typedstruct do
    field :server, pid(), enforce: true
    field :execution_id, integer(), enforce: true
    field :server_monitor, reference(), enforce: true
    field :owner_monitor, reference(), enforce: true
    field :ledger_monitor, reference()
    field :work_store_monitor, reference()
    field :transfer, Garden.WorkStore.Transfer.t()
    field :transfer_monitor, reference()
    field :transfer_cleanup, term(), default: :ok
    field :vmm_directory, String.t()
    field :directory, String.t()
    field :vmm, pid()
    field :formatter, pid()
    field :io, pid()
    field :outcome, term()
    field :cleanup_error, term()
    field :started, integer(), enforce: true
    field :options, keyword(), enforce: true
  end

  defp transfer_error(:deadline), do: {:error, :timeout}
  defp transfer_error(reason), do: {:error, {:work_store_failed, reason}}

  def run(server, options) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      server: server,
      execution_id: options[:execution_id],
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

    state =
      if options[:run_sid] do
        case GenServer.whereis(options[:work_store]) do
          nil -> %{state | outcome: {:error, :work_store_unavailable}}
          service -> %{state | work_store_monitor: Process.monitor(service)}
        end
      else
        state
      end

    registration = register(state)

    if registration != :ok or state.outcome != nil do
      finish(state, state.outcome || {:error, :owner_down}, :ok)
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

      {:cloud_hypervisor_cleanup, cleanup_owner, reference, directory} ->
        state = detach(state)
        send(cleanup_owner, {reference, state.transfer_cleanup})
        stop(state, {:error, {:vmm_exited, directory}})

      {:work_store_paths, execution_id, paths}
      when execution_id == state.execution_id ->
        notify_paths(state, execution_id, paths)
        loop(state)

      {:work_store_failed, execution_id, reason}
      when execution_id == state.execution_id ->
        stop(state, transfer_error(reason))

      {:DOWN, ref, :process, _pid, reason}
      when ref == state.work_store_monitor or ref == state.transfer_monitor ->
        stop(state, {:error, {:work_store_down, reason}})

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
           resource_cleanup_owner: if(state.options[:run_sid], do: self(), else: nil),
           readiness_timeout: Keyword.get(state.options, :deadline_ms, 60_000)
         ) do
      {:ok, vmm} ->
        status = CloudHypervisor.Process.status(vmm)
        notify_status(state, vmm: vmm, os_pid: status.os_pid, vmm_directory: status.directory)
        state = %{state | vmm: vmm, vmm_directory: status.directory}

        case attach(state) do
          {:ok, state} ->
            guard = self()

            {io, _monitor} =
              spawn_monitor(fn ->
                Garden.VM.IO.run(
                  guard,
                  vmm,
                  state.options[:command],
                  Keyword.get(state.options, :on_output, &Garden.VM.IO.output/2),
                  state.started,
                  state.transfer != nil
                )
              end)

            loop(%{state | io: io})

          {:stopped, state, result} ->
            stop(state, result)
        end

      {:error, reason} ->
        finish(state, {:error, {:vmm_startup, reason}}, :unconfirmed)
    end
  end

  defp attach(%__MODULE__{} = state) do
    if state.options[:run_sid] do
      remaining =
        Keyword.get(state.options, :deadline_ms, 60_000) -
          (System.monotonic_time(:millisecond) - state.started)

      if remaining <= 0 do
        {:stopped, state, {:error, :timeout}}
      else
        guard = self()
        reference = make_ref()

        {worker, monitor} =
          spawn_monitor(fn ->
            result =
              try do
                Garden.WorkStore.attach(
                  state.options[:work_store],
                  state.options[:run_sid],
                  state.execution_id,
                  state.vmm_directory,
                  guard,
                  remaining
                )
              catch
                :exit, reason -> {:error, {:work_store_unavailable, reason}}
              end

            send(guard, {:attached, reference, result})
          end)

        await_attach(state, worker, monitor, reference)
      end
    else
      {:ok, state}
    end
  end

  defp await_attach(%__MODULE__{} = state, worker, monitor, reference) do
    receive do
      {:attached, ^reference, {:ok, transfer}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, %{state | transfer: transfer, transfer_monitor: Process.monitor(transfer.service)}}

      {:attached, ^reference, {:error, reason}} ->
        abort_attach(state, worker, monitor, {:error, {:work_store_attach, reason}})

      {:finish, result} ->
        abort_attach(state, worker, monitor, result)

      {:work_store_failed, execution_id, reason} when execution_id == state.execution_id ->
        abort_attach(state, worker, monitor, transfer_error(reason))

      :deadline ->
        abort_attach(state, worker, monitor, {:error, :timeout})

      {:DOWN, ref, :process, _pid, _reason}
      when ref == state.owner_monitor or ref == state.server_monitor or
             ref == state.ledger_monitor ->
        abort_attach(state, worker, monitor, {:error, :owner_down})

      {:DOWN, ref, :process, _pid, reason}
      when ref == state.work_store_monitor or ref == monitor ->
        abort_attach(state, worker, monitor, {:error, {:work_store_down, reason}})

      {:cloud_hypervisor_cleanup, cleanup_owner, cleanup_reference, directory} ->
        {:stopped, state, result} =
          abort_attach(state, worker, monitor, {:error, {:vmm_exited, directory}})

        send(cleanup_owner, {cleanup_reference, state.transfer_cleanup})
        {:stopped, state, result}

      {:cloud_hypervisor, vmm, {:failed, reason}} when vmm == state.vmm ->
        abort_attach(state, worker, monitor, {:error, {:vmm_failed, reason}})

      {:EXIT, vmm, reason} when vmm == state.vmm ->
        abort_attach(state, worker, monitor, {:error, {:vmm_server_down, reason}})

      _ ->
        await_attach(state, worker, monitor, reference)
    end
  end

  defp abort_attach(%__MODULE__{} = state, worker, monitor, result) do
    Process.exit(worker, :kill)
    Process.demonitor(monitor, [:flush])
    guard = self()

    cleanup =
      transfer_cleanup(fn -> Garden.WorkStore.revoke_owner(state.options[:work_store], guard) end)

    {:stopped, %{state | transfer_cleanup: cleanup}, result}
  end

  defp detach(%__MODULE__{transfer: nil} = state), do: state

  defp detach(%__MODULE__{} = state) do
    result = transfer_cleanup(fn -> Garden.WorkStore.detach(state.transfer) end)

    Process.demonitor(state.transfer_monitor, [:flush])
    %{state | transfer: nil, transfer_monitor: nil, transfer_cleanup: result}
  end

  defp transfer_cleanup(cleanup_fun) do
    guard = self()
    reference = make_ref()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            cleanup_fun.()
          catch
            :exit, reason -> {:error, {:transfer_cleanup, reason}}
          end

        send(guard, {:transfer_cleanup, reference, result})
      end)

    result =
      receive do
        {:transfer_cleanup, ^reference, result} -> result
        {:DOWN, ^monitor, :process, ^worker, reason} -> {:error, {:transfer_cleanup, reason}}
      after
        10_000 ->
          Process.exit(worker, :kill)
          {:error, :transfer_cleanup_timeout}
      end

    Process.demonitor(monitor, [:flush])
    result
  end

  defp notify_paths(%__MODULE__{} = state, execution_id, paths) do
    send(state.server, {:vm_paths, execution_id, paths})
    notify_status(state, paths: paths)
  end

  defp drain_paths(%__MODULE__{} = state) do
    receive do
      {:work_store_paths, execution_id, paths}
      when execution_id == state.execution_id ->
        notify_paths(state, execution_id, paths)
        drain_paths(state)
    after
      0 -> :ok
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
    state = detach(state)
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
      {:cloud_hypervisor_cleanup, cleanup_owner, reference, _directory} ->
        state = detach(state)
        send(cleanup_owner, {reference, state.transfer_cleanup})
        await_stop(state)

      {:work_store_paths, execution_id, paths}
      when execution_id == state.execution_id ->
        notify_paths(state, execution_id, paths)
        await_stop(state)

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
    state = detach(state)
    drain_paths(state)

    certification =
      if state.transfer_cleanup == :ok, do: certification, else: state.transfer_cleanup

    cleanup = if certification == :ok, do: remove_known(state.directory), else: certification

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
