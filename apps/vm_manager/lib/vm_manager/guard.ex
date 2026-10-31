defmodule VMManager.Guard do
  @moduledoc false
  use TypedStruct
  alias CloudHypervisor.{Config, Launch}

  typedstruct do
    field :server, pid(), enforce: true
    field :server_monitor, reference(), enforce: true
    field :directory, String.t()
    field :vmm, pid()
    field :formatter, pid()
    field :io, pid()
    field :network, VMManager.Network.t()
    field :outcome, term()
    field :cleanup_error, term()
    field :started, integer(), enforce: true
    field :options, keyword(), enforce: true
    field :boot_timer, reference()
    field :command, pid()
    field :cancel_timer, reference()
    field :attached, boolean(), default: false
  end

  def run(server, options) do
    Process.flag(:trap_exit, true)

    options =
      Keyword.put_new(
        options,
        :boot_deadline_ms,
        if(options[:command], do: Keyword.get(options, :deadline_ms, 60_000), else: 60_000)
      )

    state = %__MODULE__{
      server: server,
      server_monitor: Process.monitor(server),
      options: options,
      started: System.monotonic_time(:millisecond)
    }

    if options[:mode] == :attach, do: attach(state), else: allocate(state)
  end

  defp attach(%__MODULE__{} = state) do
    config = state.options[:config]
    client = %CloudHypervisor.API{socket: config.control_endpoint}

    deadline = state.started + config.boot_deadline_ms

    with {:ok, info} <- CloudHypervisor.API.info(client),
         :ok <- matching_runtime(info, config),
         :ok <- boot_attached(client, info, deadline) do
      timer =
        Process.send_after(
          self(),
          :deadline,
          max(0, deadline - System.monotonic_time(:millisecond))
        )

      {io, _monitor} = start_io(state, config.guest_endpoint)
      loop(%{state | io: io, boot_timer: timer, attached: true, network: config.network_lease})
    else
      {:error, reason} -> finish(state, {:error, {:attachment, reason}}, :unconfirmed)
    end
  end

  defp matching_runtime(%CloudHypervisor.API.Info{} = info, config) do
    actual = info.config
    payload = actual["payload"] || %{}
    roots = Enum.map(actual["disks"] || [], & &1["path"])

    if (info.state == "Running" or stopped?(info)) and
         "sower.vm.id=#{config.id}" in String.split(payload["cmdline"] || "") and
         payload["kernel"] == config.kernel and payload["initramfs"] == config.initrd and
         config.root in roots and
         get_in(actual, ["cpus", "boot_vcpus"]) == config.cpus and
         get_in(actual, ["memory", "size"]) == config.memory and
         get_in(actual, ["vsock", "socket"]) == config.guest_endpoint and
         Enum.all?(config.disks, &(&1.path in roots)) and
         matching_network?(actual["net"] || [], config) do
      :ok
    else
      {:error, :runtime_identity_mismatch}
    end
  end

  defp matching_network?([], %{network: :none, network_lease: nil}), do: true

  defp matching_network?([net], %{network: :full, network_lease: %VMManager.Network{} = lease}),
    do: net["tap"] == lease.tap and net["mac"] == lease.mac

  defp matching_network?(_, _), do: false

  defp stopped?(%CloudHypervisor.API.Info{state: "Created", device_tree: nil}), do: true
  defp stopped?(%CloudHypervisor.API.Info{}), do: false

  defp boot_attached(_client, %CloudHypervisor.API.Info{state: "Running"}, _deadline), do: :ok

  defp boot_attached(
         client,
         %CloudHypervisor.API.Info{state: "Created", device_tree: nil},
         deadline
       ) do
    with :ok <- CloudHypervisor.API.boot(client),
         :ok <- await_state(client, "Running", deadline) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_state(client, expected, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :state_timeout}
    else
      case CloudHypervisor.API.info(%{client | request_timeout: min(client.timeout, remaining)}) do
        {:ok, info} ->
          if info.state == expected and (expected != "Created" or stopped?(info)) do
            :ok
          else
            Process.sleep(min(25, remaining))
            await_state(client, expected, deadline)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp start_io(%__MODULE__{} = state, path) do
    guard = self()

    spawn_monitor(fn ->
      VMManager.IO.run(guard, path, state.options[:image].contract, state.started)
    end)
  end

  defp allocate(%__MODULE__{} = state) do
    options = state.options

    timer =
      Process.send_after(
        self(),
        :deadline,
        Keyword.get(options, :boot_deadline_ms, Keyword.get(options, :deadline_ms, 60_000))
      )

    state = %{state | boot_timer: timer}

    base = options[:resource_directory] || System.tmp_dir!()
    attempt = options[:attempt] || "#{System.pid()}-#{System.unique_integer([:positive])}"
    directory = runtime_directory(base, attempt)

    with :ok <- prepare_base(options[:resource_directory]),
         :ok <- File.mkdir(directory) do
      prepare(%{state | directory: directory})
    else
      {:error, reason} ->
        finish(state, {:error, {:resource_directory, reason}}, :ok)
    end
  end

  defp prepare_base(nil), do: :ok

  defp prepare_base(directory) do
    with :ok <- File.mkdir_p(Path.dirname(directory)) do
      case File.mkdir(directory) do
        :ok -> File.chmod(directory, 0o700)
        {:error, :eexist} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
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

      :deadline when state.boot_timer != nil ->
        stop(state, {:error, :timeout})

      :cleanup_deadline ->
        finish(state, state.outcome, :shutdown_timeout)

      {:DOWN, ref, :process, _pid, _reason}
      when ref == state.server_monitor ->
        stop(state, {:error, :owner_down})

      {:DOWN, _ref, :process, io, reason} when io == state.io ->
        stop(state, {:error, {:io_down, reason}})

      {:guest_ready, _ready} ->
        Process.cancel_timer(state.boot_timer)
        notify_status(state, phase: :ready)
        loop(%{state | boot_timer: nil})

      {:execute, command, request, callback} when state.command == nil ->
        send(state.io, {:execute, command, request, callback})

        notify_status(state,
          phase: if(state.options[:command], do: :running, else: :running_command)
        )

        loop(%{state | command: command})

      {:guest_reconnecting, command} when command == state.command ->
        timer =
          state.cancel_timer || Process.send_after(self(), {:cancel_deadline, command}, 5_000)

        loop(%{state | cancel_timer: timer})

      {:cancel_command, command, reason} when command == state.command ->
        send(state.io, {:cancel, command, reason})

        timer =
          state.cancel_timer || Process.send_after(self(), {:cancel_deadline, command}, 5_000)

        loop(%{state | cancel_timer: timer})

      {:cancel_deadline, command} when command == state.command ->
        stop(state, {:error, :command_cleanup_unconfirmed})

      {:command_finished, command, result} when command == state.command ->
        if state.cancel_timer, do: Process.cancel_timer(state.cancel_timer)
        send(state.server, {:command_finished, command, result})
        state = %{state | command: nil, cancel_timer: nil}

        if state.options[:command] || state.options[:image].contract == 1 do
          stop(state, result)
        else
          notify_status(state, phase: :ready)
          loop(state)
        end

      {:cloud_hypervisor, vmm, {:ready, status}} when vmm == state.vmm ->
        notify_status(state, vmm: vmm, os_pid: status.os_pid)
        {io, _monitor} = start_io(state, Path.join(status.directory, "vsock.sock"))
        loop(%{state | io: io})

      {:cloud_hypervisor, vmm, {:exited, {:exit_status, 0} = outcome}} when vmm == state.vmm ->
        stop(state, {:ok, {:vmm_exited, outcome}})

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
    case VMManager.Network.provision(state.options) do
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
      when ref == state.server_monitor ->
        stop(state, {:error, :owner_down})
    after
      0 ->
        if System.monotonic_time(:millisecond) - state.started >=
             Keyword.get(
               state.options,
               :boot_deadline_ms,
               Keyword.get(state.options, :deadline_ms, 60_000)
             ),
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
      cmdline:
        image.cmdline <> " sower.vm.id=#{image.id}" <> VMManager.Network.cmdline(state.network),
      cpus: %Config.CPUs{boot_vcpus: cpus, max_vcpus: cpus},
      memory: Keyword.get(state.options, :memory, 512 * 1024 * 1024),
      disks:
        [
          %Config.Disk{path: image.root, readonly: true, image_type: :raw},
          %Config.Disk{
            path: Path.join(state.directory, "scratch.ext4"),
            readonly: false,
            image_type: :raw
          }
        ] ++ image.disks,
      net: VMManager.Network.devices(state.network),
      serial: %Config.Output{mode: :file, file: Path.join(state.directory, "serial.log")},
      console: %Config.Output{mode: :off},
      rng: %Config.RNG{src: "/dev/urandom"},
      vsock: %Config.Vsock{cid: 3, socket: nil}
    }

    case CloudHypervisor.Process.start_link(
           config: config,
           owner: self(),
           before_stop: fn -> VMManager.Network.revoke(state.network) end,
           launch: %Launch{
             executable: Keyword.get(state.options, :hypervisor, "cloud-hypervisor")
           },
           readiness_timeout:
             Keyword.get(
               state.options,
               :boot_deadline_ms,
               Keyword.get(state.options, :deadline_ms, 60_000)
             )
         ) do
      {:ok, vmm} ->
        loop(%{state | vmm: vmm})

      {:error, reason} ->
        finish(state, {:error, {:vmm_startup, reason}}, :unconfirmed)
    end
  end

  defp shutdown_attached(_client, %CloudHypervisor.API.Info{state: "Created", device_tree: nil}),
    do: :ok

  defp shutdown_attached(client, %CloudHypervisor.API.Info{state: "Running"}),
    do: CloudHypervisor.API.shutdown(client)

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

  defp stop(%__MODULE__{attached: true} = state, result) do
    notify_status(state, phase: :stopping)
    if state.io, do: Process.exit(state.io, :kill)
    client = %CloudHypervisor.API{socket: state.options[:control_endpoint]}

    cleanup =
      with {:ok, running} <- CloudHypervisor.API.info(client),
           :ok <- matching_runtime(running, state.options[:config]),
           :ok <- VMManager.Network.revoke(state.network),
           :ok <- shutdown_attached(client, running),
           :ok <- await_state(client, "Created", System.monotonic_time(:millisecond) + 10_000) do
        :ok
      else
        error -> {:error, {:external_shutdown, error}}
      end

    finish(state, result, cleanup)
  end

  defp stop(%__MODULE__{vmm: nil} = state, result), do: finish(state, result, :ok)

  defp stop(%__MODULE__{} = state, result) do
    notify_status(state, phase: :stopping)
    if state.io, do: Process.exit(state.io, :kill)
    revocation = VMManager.Network.revoke(state.network)
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
      case VMManager.Network.revoke(state.network) do
        :ok when certification == :ok -> VMManager.Network.release(state.network)
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

    if state.options[:cleanup_path] do
      VMManager.Store.write_certificate(
        state.options[:cleanup_path],
        state.options[:attempt],
        result,
        cleanup
      )
    end

    send(state.server, {:vm_finished, result, cleanup})
  end

  defp revocation_error(:ok), do: nil
  defp revocation_error(error), do: error

  defp notify_status(%__MODULE__{} = state, changes) do
    send(state.server, {:vm_status, changes})
  end

  def runtime_directory(base, attempt), do: Path.join(base, "sower-vm-" <> attempt)

  def cleanup_runtime(_base, nil), do: :ok
  def cleanup_runtime(base, attempt), do: remove_known(runtime_directory(base, attempt))

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
