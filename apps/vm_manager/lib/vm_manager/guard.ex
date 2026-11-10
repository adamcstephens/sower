defmodule VMManager.Guard do
  @moduledoc """
  Owns the resource lifecycle for one launched or attached VM attempt.

  It prepares storage and networking, starts or verifies the VMM, monitors the
  execution controller and guest session, and coordinates teardown. Attached
  runtimes are checked against the requested configuration before admission.
  Cleanup failures are reported as unconfirmed rather than certified success.
  """
  use TypedStruct
  alias CloudHypervisor.Launch

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
    field :formatters, [[String.t()]], default: []
    field :attached, boolean(), default: false
    field :observation_timeouts, non_neg_integer(), default: 0
    field :stop_worker, pid()
    field :stop_mode, :graceful | :force
  end

  def run(server, options) do
    Process.flag(:trap_exit, true)

    options = Keyword.put_new(options, :boot_deadline_ms, 60_000)

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

    with {:ok, info} <- CloudHypervisor.API.info(client),
         :ok <- matching_runtime(info, state) do
      state = %{state | attached: true, network: state.options[:network] || config.network}

      case checkpoint_network(state) do
        :ok ->
          admit_attachment(state, client, info, state.started + config.boot_deadline_ms)

        {:error, reason} ->
          stop(state, {:error, reason})
      end
    else
      {:error, reason} -> finish(state, {:error, {:attachment, reason}}, :unconfirmed)
    end
  end

  defp admit_attachment(%__MODULE__{} = state, client, info, deadline) do
    receive do
      {:stop, policy} ->
        stop(state, :ok, policy)

      {:finish, result} ->
        stop(state, result)

      {:DOWN, ref, :process, _pid, _reason} when ref == state.server_monitor ->
        stop(state, {:error, :owner_down})
    after
      0 ->
        with true <- System.monotonic_time(:millisecond) < deadline,
             :ok <- boot_attached(client, info, deadline) do
          timer =
            Process.send_after(
              self(),
              :deadline,
              max(0, deadline - System.monotonic_time(:millisecond))
            )

          config = state.options[:config]

          running(%{state | boot_timer: timer}, get_in(config.vsock.socket))
        else
          false -> stop(state, {:error, :timeout})
          {:error, reason} -> stop(state, {:error, {:attachment, reason}})
        end
    end
  end

  defp matching_runtime(
         %CloudHypervisor.API.Info{} = info,
         %__MODULE__{} = state,
         stage \\ :admission
       ) do
    matches =
      if stage == :stopping,
        do: &VMManager.Machine.matches_configuration?/4,
        else: &VMManager.Machine.matches?/4

    if matches.(
         info,
         state.options[:config],
         state.directory,
         state.network || state.options[:network] || state.options[:config].network
       ),
       do: :ok,
       else: {:error, :runtime_identity_mismatch}
  end

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

  defp running(%__MODULE__{} = state, path) do
    config = state.options[:config]
    if state.attached, do: Process.send_after(self(), :observe_attachment, 250)

    if config.guest == :none do
      if state.boot_timer, do: Process.cancel_timer(state.boot_timer)
      notify_status(state, running: true, phase: :running)
      loop(%{state | boot_timer: nil})
    else
      notify_status(state, running: true)

      {:ok, session} =
        VMManager.Guest.Session.start(self(), state.server, path, state.options, state.started)

      Process.monitor(session)
      loop(%{state | io: session})
    end
  end

  defp observe_attachment(%__MODULE__{} = state) do
    client = %CloudHypervisor.API{
      socket: state.options[:config].control_endpoint,
      request_timeout: 250
    }

    with {:ok, info} <- CloudHypervisor.API.info(client),
         :ok <- matching_runtime(info, state) do
      if stopped?(info) do
        notify_status(state, running: false, phase: :stopping)
        finish(state, {:ok, :external_shutdown}, :ok)
      else
        Process.send_after(self(), :observe_attachment, 250)
        loop(%{state | observation_timeouts: 0})
      end
    else
      {:error, reason} ->
        if observation_timeout?(reason) and state.observation_timeouts < 2 do
          Process.send_after(self(), :observe_attachment, 250)
          loop(%{state | observation_timeouts: state.observation_timeouts + 1})
        else
          notify_status(state, running: false, phase: :stopping)
          finish(state, {:error, {:attachment, reason}}, :unconfirmed)
        end
    end
  end

  defp observation_timeout?(%CloudHypervisor.API.Error{
         kind: :transport,
         reason: %Req.TransportError{reason: :timeout}
       }),
       do: true

  defp observation_timeout?(%CloudHypervisor.API.Error{
         kind: :transport,
         reason: {:pool_timeout, _error}
       }),
       do: true

  defp observation_timeout?(_reason), do: false

  defp allocate(%__MODULE__{} = state) do
    options = state.options

    timer =
      Process.send_after(
        self(),
        :deadline,
        options[:boot_deadline_ms]
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
    notify_status(state, directory: state.directory)

    with :ok <- File.chmod(state.directory, 0o700),
         {:ok, formatters} <- VMManager.Storage.prepare(state.options[:config], state.directory) do
      start_formatter(%{state | formatters: formatters})
    else
      {:error, reason} -> finish(state, {:error, {:storage_startup, reason}}, :ok)
    end
  end

  defp start_formatter(%__MODULE__{formatters: []} = state), do: launch(state)

  defp start_formatter(%__MODULE__{formatters: [command | rest]} = state) do
    case Rexec.run_link(command, owner: self()) do
      {:ok, formatter, _os_pid} -> loop(%{state | formatter: formatter, formatters: rest})
      {:error, reason} -> finish(state, {:error, {:storage_startup, reason}}, :unconfirmed)
    end
  end

  defp loop(%__MODULE__{} = state) do
    receive do
      {:EXIT, formatter, reason} when formatter == state.formatter ->
        case CloudHypervisor.Cleanup.completion(reason) do
          {:ok, {:exit_status, 0}} when state.cleanup_error == nil ->
            if state.outcome,
              do: finish(state, state.outcome, :ok),
              else: start_formatter(%{state | formatter: nil})

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

      {:stop, policy} ->
        stop(state, :ok, policy)

      {:finish, result} ->
        stop(state, result)

      :observe_attachment when state.attached ->
        observe_attachment(state)

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
        if state.boot_timer, do: Process.cancel_timer(state.boot_timer)
        loop(%{state | boot_timer: nil})

      {:cloud_hypervisor, vmm, {:ready, status}} when vmm == state.vmm ->
        notify_status(state, vmm: vmm, os_pid: status.os_pid)

        path = Path.join(status.directory, "vsock.sock")

        running(%{state | vmm: vmm}, path)

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
    config = state.options[:config]

    allocation_id =
      {state.options[:name], config.id, state.options[:attempt] || state.directory}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    case VMManager.Network.provision(config, allocation_id) do
      {:ok, network} ->
        state = %{state | network: network}

        case checkpoint_network(state) do
          :ok -> admit_launch(state)
          {:error, reason} -> finish(state, {:error, reason}, :ok)
        end

      {:error, {:network_provision_unconfirmed, _} = reason} ->
        finish(state, {:error, reason}, :unconfirmed)

      {:error, reason} ->
        finish(state, {:error, reason}, :ok)
    end
  end

  defp checkpoint_network(%__MODULE__{} = state) do
    case state.options[:manager] do
      nil ->
        :ok

      manager ->
        try do
          GenServer.call(
            manager,
            {:checkpoint_network, state.options[:execution_id], state.options[:attempt],
             state.network},
            :infinity
          )
        catch
          :exit, reason -> {:error, {:network_checkpoint, reason}}
        end
    end
  end

  defp admit_launch(%__MODULE__{} = state) do
    receive do
      {:stop, policy} ->
        stop(state, :ok, policy)

      {:finish, result} ->
        stop(state, result)

      :deadline ->
        stop(state, {:error, :timeout})

      {:DOWN, ref, :process, _pid, _reason}
      when ref == state.server_monitor ->
        stop(state, {:error, :owner_down})
    after
      0 ->
        if System.monotonic_time(:millisecond) - state.started >= state.options[:boot_deadline_ms],
          do: stop(state, {:error, :timeout}),
          else: launch_vm(state)
    end
  end

  defp launch_vm(%__MODULE__{} = state) do
    config = VMManager.Machine.build(state.options[:config], state.directory, state.network)

    case CloudHypervisor.Process.start_link(
           config: config,
           owner: self(),
           before_stop: fn -> VMManager.Network.revoke(state.network) end,
           launch: %Launch{
             executable: Keyword.get(state.options, :hypervisor, "cloud-hypervisor")
           },
           readiness_timeout: state.options[:boot_deadline_ms]
         ) do
      {:ok, vmm} ->
        loop(%{state | vmm: vmm})

      {:error, reason} ->
        finish(state, {:error, {:vmm_startup, reason}}, :unconfirmed)
    end
  end

  defp stop(%__MODULE__{} = state, result),
    do: stop(state, result, %VMManager.Stop{mode: :force})

  defp stop(%__MODULE__{outcome: outcome} = state, _result, _policy)
       when not is_nil(outcome),
       do: loop(state)

  defp stop(%__MODULE__{formatter: formatter} = state, result, _policy)
       when not is_nil(formatter) do
    notify_status(state, phase: :stopping)

    try do
      Rexec.kill_tree(formatter, :sigkill)
    catch
      :exit, _reason -> :ok
    end

    Process.send_after(self(), :cleanup_deadline, 10_000)
    loop(%{state | outcome: result})
  end

  defp stop(%__MODULE__{attached: true} = state, result, policy) do
    notify_status(state, phase: :stopping)
    stop_session(state.io)
    guard = self()
    worker = spawn(fn -> send(guard, {:stopped, stop_attached(state, policy)}) end)
    Process.send_after(self(), :cleanup_deadline, policy.guest_shutdown_timeout_ms + 11_000)
    await_stop(%{state | outcome: result, stop_worker: worker, stop_mode: policy.mode})
  end

  defp stop(%__MODULE__{vmm: nil} = state, result, _policy),
    do: finish(state, result, :ok)

  defp stop(%__MODULE__{} = state, result, policy) do
    notify_status(state, phase: :stopping)
    stop_session(state.io)
    revocation = VMManager.Network.revoke(state.network)
    start_owned_stop(state, policy)
    Process.send_after(self(), :cleanup_deadline, policy.guest_shutdown_timeout_ms + 10_000)

    await_stop(%{
      state
      | outcome: result,
        cleanup_error: revocation_error(revocation),
        stop_mode: policy.mode
    })
  end

  defp start_owned_stop(%__MODULE__{} = state, policy) do
    guard = self()
    vmm = state.vmm

    spawn(fn ->
      cleanup =
        try do
          case CloudHypervisor.Process.stop(vmm, policy.mode, policy.guest_shutdown_timeout_ms) do
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
  end

  defp stop_attached(%__MODULE__{} = state, %VMManager.Stop{} = policy) do
    client = %CloudHypervisor.API{socket: state.options[:control_endpoint], request_timeout: 250}

    with {:ok, info} <- CloudHypervisor.API.info(client),
         :ok <- matching_runtime(info, state, :stopping) do
      revocation = VMManager.Network.revoke(state.network)

      cleanup =
        cond do
          stopped?(info) ->
            :ok

          policy.mode == :force ->
            force_attached(state, client, info)

          true ->
            deadline = System.monotonic_time(:millisecond) + policy.guest_shutdown_timeout_ms

            case CloudHypervisor.API.power_button(client) do
              :ok -> await_guest_stop(state, client, deadline)
              {:error, _reason} -> force_attached(state, client)
            end
        end

      if cleanup == :ok, do: revocation, else: cleanup
    else
      error -> {:error, {:external_shutdown, error}}
    end
  end

  defp await_guest_stop(%__MODULE__{} = state, client, deadline) do
    receive do
      :force -> force_attached(state, client)
    after
      0 ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          force_attached(state, client)
        else
          with {:ok, info} <-
                 CloudHypervisor.API.info(%{client | request_timeout: min(250, remaining)}),
               :ok <- matching_runtime(info, state, :stopping) do
            if stopped?(info) do
              :ok
            else
              receive do
                :force -> force_attached(state, client)
              after
                min(25, remaining) -> await_guest_stop(state, client, deadline)
              end
            end
          else
            error -> {:error, {:external_shutdown, error}}
          end
        end
    end
  end

  defp force_attached(%__MODULE__{} = state, client) do
    with {:ok, info} <- CloudHypervisor.API.info(client),
         :ok <- matching_runtime(info, state, :stopping) do
      force_attached(state, client, info)
    else
      error -> {:error, {:external_shutdown, error}}
    end
  end

  defp force_attached(%__MODULE__{} = state, client, info) do
    if stopped?(info) do
      :ok
    else
      with :ok <- CloudHypervisor.API.shutdown(client) do
        await_attached_stop(state, client, System.monotonic_time(:millisecond) + 10_000)
      else
        error ->
          with {:ok, info} <- CloudHypervisor.API.info(client),
               :ok <- matching_runtime(info, state, :stopping),
               true <- stopped?(info) do
            :ok
          else
            _ -> {:error, {:external_shutdown, error}}
          end
      end
    end
  end

  defp await_attached_stop(%__MODULE__{} = state, client, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :shutdown_timeout}
    else
      with {:ok, info} <- CloudHypervisor.API.info(client),
           :ok <- matching_runtime(info, state, :stopping) do
        if stopped?(info) do
          :ok
        else
          Process.sleep(25)
          await_attached_stop(state, client, deadline)
        end
      else
        error -> {:error, {:external_shutdown, error}}
      end
    end
  end

  defp await_stop(%__MODULE__{} = state) do
    receive do
      {:stop, %VMManager.Stop{mode: :force}} when state.stop_mode != :force ->
        await_stop(escalate_stop(state))

      {:finish, {:error, _reason}} ->
        await_stop(escalate_stop(state))

      {:DOWN, ref, :process, _pid, _reason} when ref == state.server_monitor ->
        await_stop(escalate_stop(%{state | outcome: {:error, :owner_down}}))

      {:stopped, :ok} ->
        finish(state, state.outcome, :ok)

      {:stopped, {:ok, _}} ->
        if state.vmm, do: GenServer.stop(state.vmm, :normal)
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

  defp escalate_stop(%__MODULE__{stop_mode: :force} = state), do: state

  defp escalate_stop(%__MODULE__{attached: true} = state) do
    send(state.stop_worker, :force)
    %{state | stop_mode: :force}
  end

  defp escalate_stop(%__MODULE__{} = state) do
    start_owned_stop(state, %VMManager.Stop{mode: :force})
    %{state | stop_mode: :force}
  end

  defp finish(%__MODULE__{} = state, result, certification) do
    stop_session(state.io)

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
        true -> VMManager.Storage.cleanup(state.options[:config], state.directory)
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

    if state.io do
      try do
        GenServer.call(state.io, {:finish, result})
      catch
        :exit, _ -> :ok
      end
    end

    send(state.server, {:vm_finished, result, cleanup})
  end

  defp revocation_error(:ok), do: nil
  defp revocation_error(error), do: error

  defp notify_status(%__MODULE__{} = state, changes) do
    send(state.server, {:vm_status, changes})
  end

  defp stop_session(nil), do: :ok

  defp stop_session(session) do
    try do
      GenServer.call(session, :quiesce)
    catch
      :exit, _ -> :ok
    end
  end

  def runtime_directory(base, attempt), do: Path.join(base, "sower-vm-" <> attempt)
end
