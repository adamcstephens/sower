defmodule VMManager.Manager do
  use GenServer
  use TypedStruct
  alias VMManager.{Config, Status, Store}

  typedstruct module: Definition do
    field :config, Config.t(), enforce: true
    field :desired, atom(), default: :stopped
    field :attempts, [integer()], default: []
    field :retry_at, integer()
    field :failure, term()
    field :reserved, boolean(), default: false
    field :boot_id, String.t()
    field :attempt, String.t()
    field :beam_identity, String.t()
    field :observed, Status.t()
  end

  typedstruct do
    field :directory, String.t(), enforce: true
    field :identity, term(), enforce: true
    field :supervisor, term(), enforce: true
    field :budgets, keyword(), enforce: true
    field :definitions, map(), default: %{}
    field :statuses, map(), default: %{}
    field :subscribers, map(), default: %{}
    field :stops, map(), default: %{}
    field :activator_socket, String.t()
    field :boot_id, String.t(), enforce: true
    field :mode, atom(), default: :running
  end

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl GenServer
  def init(options) do
    directory = Keyword.fetch!(options, :state_directory)

    with {:ok, definitions} <- Store.load(directory),
         {:ok, boot_id} <- boot_identity(options) do
      state = %__MODULE__{
        directory: directory,
        identity: Keyword.get(options, :manager_id, directory),
        supervisor: Keyword.get(options, :runtime_supervisor, VMManager.RuntimeSupervisor),
        budgets:
          Keyword.get(options, :budgets,
            vms: 1,
            cpus: 1,
            memory: 536_870_912,
            scratch_bytes: 4_294_967_296
          ),
        activator_socket: Keyword.get(options, :activator_socket),
        definitions: definitions,
        boot_id: boot_id
      }

      send(self(), :reconcile)
      {:ok, state}
    else
      {:error, {:boot_identity, _reason} = reason} -> {:stop, reason}
      {:error, reason} -> {:stop, {:durable_store, reason}}
    end
  end

  defp boot_identity(options) do
    case Keyword.fetch(options, :boot_id_file) do
      {:ok, path} -> read_boot_identity(path)
      :error -> host_boot_identity(:os.type())
    end
  end

  defp host_boot_identity({:unix, :darwin}) do
    case System.cmd("/usr/sbin/sysctl", ["-n", "kern.bootsessionuuid"]) do
      {identity, 0} -> {:ok, String.trim(identity)}
      {_output, code} -> {:error, {:boot_identity, {:sysctl_exit, code}}}
    end
  end

  defp host_boot_identity(_platform), do: read_boot_identity("/proc/sys/kernel/random/boot_id")

  defp read_boot_identity(path) do
    case File.read(path) do
      {:ok, identity} -> {:ok, String.trim(identity)}
      {:error, reason} -> {:error, {:boot_identity, {path, reason}}}
    end
  end

  @impl GenServer
  def handle_call(request, _from, %__MODULE__{mode: :stopping} = state)
      when is_tuple(request) and
             elem(request, 0) in [:define, :update, :start, :stop, :remove, :delete_storage],
      do: {:reply, {:error, :draining}, state}

  def handle_call({:define, %Config{} = config}, _from, state) do
    with :ok <- Config.validate(config), false <- Map.has_key?(state.definitions, config.id) do
      commit_reply(
        {:ok, config.id},
        put_definition(state, config.id, %Definition{config: config}),
        state
      )
    else
      true -> {:reply, {:error, :already_defined}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:update, id, %Config{} = config}, _from, state) do
    with {:ok, definition} <- fetch(state, id),
         :ok <- stopped(state, id),
         :ok <- Config.validate(config),
         true <- config.id == id do
      commit_reply(:ok, put_definition(state, id, %{definition | config: config}), state)
    else
      false -> {:reply, {:error, :identity_mismatch}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start, id}, _from, state) do
    with {:ok, definition} <- fetch(state, id),
         :ok <- startable(state, id, definition),
         :ok <- capacity(state, id, definition.config) do
      definition = %{definition | desired: :running, failure: nil, attempts: [], retry_at: nil}
      proposed = put_definition(state, id, definition)

      case persist(proposed) do
        :ok ->
          {:reply, :ok,
           if(runtime(proposed, id), do: proposed, else: launch(proposed, id, definition))}

        {:error, reason} ->
          {:reply, {:error, {:durable_store, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop, id}, from, state) do
    with {:ok, definition} <- fetch(state, id) do
      definition = %{definition | desired: :stopped, retry_at: nil, failure: nil}
      proposed = put_definition(state, id, definition)

      case persist(proposed) do
        :ok ->
          case runtime(proposed, id) do
            nil ->
              if definition.reserved do
                {:reply, {:error, :cleanup_uncertain}, proposed}
              else
                observed = %{(definition.observed || %Status{}) | phase: :stopped, cleanup: :ok}
                updated = put_definition(proposed, id, %{definition | observed: observed})

                case persist(updated) do
                  :ok -> {:reply, :ok, publish(updated, id, observed)}
                  {:error, reason} -> {:reply, {:error, {:durable_store, reason}}, proposed}
                end
              end

            pid ->
              GenServer.cast(pid, {:finish, :ok})
              send(self(), :reconcile)

              {:noreply,
               %{proposed | stops: Map.update(proposed.stops, id, [from], &[from | &1])}}
          end

        {:error, reason} ->
          {:reply, {:error, {:durable_store, reason}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, id}, _from, state) do
    case fetch(state, id) do
      {:ok, definition} -> {:reply, {:ok, status(state, id, definition)}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call(:list, _from, state),
    do:
      {:reply,
       {:ok,
        Enum.map(state.definitions, fn {id, definition} -> status(state, id, definition) end)},
       state}

  def handle_call({:subscribe, id, pid}, _from, state) do
    case fetch(state, id) do
      {:ok, _} ->
        Process.monitor(pid)

        {:reply, :ok,
         %{
           state
           | subscribers:
               Map.update(state.subscribers, id, MapSet.new([pid]), &MapSet.put(&1, pid))
         }}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:remove, id}, _from, state) do
    with {:ok, _} <- fetch(state, id), :ok <- stopped(state, id) do
      commit_reply(
        :ok,
        %{
          state
          | definitions: Map.delete(state.definitions, id),
            statuses: Map.delete(state.statuses, id)
        },
        state
      )
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_storage, id}, _from, state) do
    with {:ok, definition} <- fetch(state, id), :ok <- stopped(state, id) do
      result =
        Enum.reduce_while(definition.config.persistent_disks, :ok, fn path, :ok ->
          case File.rm(path) do
            :ok -> {:cont, :ok}
            {:error, :enoent} -> {:cont, :ok}
            error -> {:halt, error}
          end
        end)

      {:reply, result, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:prepare_shutdown, _from, state) do
    state = %{state | mode: :stopping}

    {definitions, errors} =
      Enum.reduce(state.definitions, {%{}, []}, fn {id, definition}, {definitions, errors} ->
        result =
          case runtime(state, id) do
            nil -> if(definition.reserved, do: {:error, :cleanup_uncertain}, else: :ok)
            pid -> stop_runtime(pid)
          end

        definition =
          if(result == :ok,
            do: %{
              definition
              | reserved: false,
                observed: %{(definition.observed || %Status{}) | phase: :stopped, cleanup: :ok}
            },
            else: definition
          )

        errors = if(result == :ok, do: errors, else: [{id, result} | errors])
        {Map.put(definitions, id, definition), errors}
      end)

    proposed = %{state | definitions: definitions}
    result = if(errors == [], do: :ok, else: {:error, {:cleanup_incomplete, errors}})
    commit_reply(result, proposed, state)
  end

  @impl GenServer
  def handle_info(message, %__MODULE__{mode: :stopping} = state)
      when message in [:reconcile, :tick],
      do: {:noreply, state}

  def handle_info(:reconcile, state) do
    state = Enum.reduce(Map.keys(state.definitions), state, &reconcile/2)

    if Process.get(:reconcile_timer) == nil do
      Process.put(:reconcile_timer, Process.send_after(self(), :tick, 100))
    end

    {:noreply, state}
  end

  def handle_info(:tick, state) do
    Process.delete(:reconcile_timer)
    handle_info(:reconcile, state)
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply,
     %{
       state
       | subscribers:
           Map.new(state.subscribers, fn {id, subscribers} ->
             {id, MapSet.delete(subscribers, pid)}
           end)
     }}
  end

  defp reconcile(id, state) do
    definition = Map.fetch!(state.definitions, id)

    case runtime(state, id) do
      nil ->
        certificate = Store.certificate(certificate_path(state, id))

        cond do
          definition.reserved and definition.boot_id != state.boot_id ->
            recover_host(state, id, definition)

          definition.reserved and
              match?({:ok, %{attempt: attempt}} when attempt == definition.attempt, certificate) ->
            {:ok, certificate} = certificate

            observed = %{
              (definition.observed || %Status{})
              | phase: :stopped,
                result: certificate.result,
                cleanup: certificate.cleanup
            }

            finish(publish(state, id, observed), id, definition, observed, nil)

          definition.reserved and definition.desired == :running and
            definition.config.mode == :attach and definition.beam_identity != beam_identity() ->
            launch(state, id, definition)

          definition.reserved ->
            publish(state, id, %{
              (definition.observed || %Status{})
              | phase: :retained,
                cleanup: :unknown,
                failure: :controller_lost
            })

          definition.desired == :running and definition.failure == nil and due?(definition) ->
            launch(state, id, definition)

          true ->
            state
        end

      pid ->
        case runtime_status(pid) do
          {:ok, observed} ->
            durable = %{observed | execution: nil, guard: nil, owner: nil, vmm: nil}

            state =
              if definition.observed != durable do
                proposed = put_definition(state, id, %{definition | observed: durable})

                case persist(proposed) do
                  :ok -> proposed
                  {:error, _} -> state
                end
              else
                state
              end

            definition = state.definitions[id]
            state = publish(state, id, %{observed | execution: pid})

            if observed.phase in [:stopped, :finished, :retained] do
              finish(state, id, definition, observed, pid)
            else
              state
            end

          :unavailable ->
            publish(state, id, %Status{
              phase: :retained,
              cleanup: :unknown,
              failure: :controller_lost
            })
        end
    end
  end

  defp launch(state, id, definition) do
    case capacity(state, id, definition.config) do
      :ok ->
        config = %{
          definition.config
          | runtime_directory:
              definition.config.runtime_directory || Path.join(state.directory, "runtimes")
        }

        attempt = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

        observed = %Status{
          phase: :booting,
          cleanup: :pending,
          directory:
            if(config.mode == :launch,
              do: VMManager.Guard.runtime_directory(config.runtime_directory, attempt),
              else: nil
            )
        }

        proposed =
          put_definition(state, id, %{
            definition
            | config: config,
              reserved: true,
              boot_id: state.boot_id,
              beam_identity: beam_identity(),
              attempt: attempt,
              observed: observed
          })

        case persist(proposed) do
          :ok ->
            options =
              Config.to_options(config)
              |> Keyword.merge(
                name: {:via, Registry, {VMManager.Registry, {state.identity, id}}},
                owner: GenServer.whereis(state.supervisor),
                activator_socket: state.activator_socket,
                cleanup_path: certificate_path(state, id),
                attempt: attempt
              )

            case DynamicSupervisor.start_child(state.supervisor, {VMManager.Execution, options}) do
              {:ok, _pid} -> proposed
              {:error, reason} -> failed_launch(proposed, id, reason)
            end

          {:error, reason} ->
            publish(state, id, %Status{phase: :failed, failure: {:durable_store, reason}})
        end

      {:error, reason} ->
        publish(state, id, %Status{phase: :failed, failure: reason})
    end
  end

  defp recover_host(state, id, %Definition{} = definition) do
    cleanup =
      if definition.config.mode == :launch and definition.attempt != nil do
        base = definition.config.runtime_directory || Path.join(state.directory, "runtimes")
        VMManager.Guard.cleanup_runtime(base, definition.attempt)
      else
        :ok
      end

    observed = %{
      (definition.observed || %Status{})
      | phase: if(cleanup == :ok, do: :stopped, else: :retained),
        cleanup: cleanup,
        failure: if(cleanup == :ok, do: nil, else: {:host_restore_cleanup, cleanup}),
        execution: nil,
        guard: nil,
        owner: nil,
        vmm: nil
    }

    updated = %{definition | reserved: cleanup != :ok, observed: observed}
    proposed = put_definition(state, id, updated)
    result = if updated == definition, do: :ok, else: persist(proposed)

    case result do
      :ok ->
        proposed = publish(proposed, id, observed)
        if cleanup == :ok, do: reconcile(id, proposed), else: proposed

      {:error, _reason} ->
        state
    end
  end

  defp failed_launch(state, id, reason) do
    definition = state.definitions[id]
    observed = %Status{phase: :failed, result: {:error, {:launch_failed, reason}}, cleanup: :ok}
    updated = restart(%{definition | reserved: false}, observed)
    proposed = put_definition(state, id, updated)

    case persist(proposed) do
      :ok -> publish(proposed, id, observed)
      {:error, _} -> state
    end
  end

  defp finish(state, id, definition, observed, pid) do
    if observed.cleanup == :ok do
      observed =
        if definition.desired == :stopped, do: %{observed | phase: :stopped}, else: observed

      waiters = Map.get(state.stops, id, [])
      durable = %{observed | execution: nil, guard: nil, owner: nil, vmm: nil}
      definition = %{definition | reserved: false, observed: durable}
      definition = restart(definition, observed)
      proposed = put_definition(%{state | stops: Map.delete(state.stops, id)}, id, definition)

      case persist(proposed) do
        :ok ->
          if pid, do: DynamicSupervisor.terminate_child(state.supervisor, pid)
          proposed = publish(proposed, id, durable)
          Enum.each(waiters, &GenServer.reply(&1, :ok))
          proposed

        {:error, _reason} ->
          state
      end
    else
      Enum.each(
        Map.get(state.stops, id, []),
        &GenServer.reply(&1, {:error, {:cleanup_incomplete, observed.cleanup}})
      )

      %{state | stops: Map.delete(state.stops, id)}
    end
  end

  defp restart(%Definition{desired: :stopped} = definition, _observed), do: definition

  defp restart(%Definition{} = definition, %Status{} = observed) do
    config = definition.config
    failed = observed.result not in [:ok, nil] and not match?({:ok, _}, observed.result)

    if config.restart == :always or (config.restart == :on_failure and failed) do
      now = System.system_time(:millisecond)
      attempts = Enum.filter(definition.attempts, &(&1 > now - config.restart_window_ms))

      if length(attempts) < config.restart_max_attempts do
        %{
          definition
          | attempts: [now | attempts],
            retry_at: now + config.restart_delay_ms,
            failure: nil
        }
      else
        %{definition | attempts: attempts, failure: :restart_exhausted, retry_at: nil}
      end
    else
      %{
        definition
        | failure: if(failed, do: {:vm_failed, observed.result}, else: :terminated),
          retry_at: nil
      }
    end
  end

  defp due?(%Definition{retry_at: nil}), do: true

  defp due?(%Definition{} = definition),
    do: definition.retry_at <= System.system_time(:millisecond)

  defp fetch(state, id) do
    case Map.fetch(state.definitions, id) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, :not_found}
    end
  end

  defp put_definition(state, id, definition),
    do: %{state | definitions: Map.put(state.definitions, id, definition)}

  defp persist(state), do: Store.save(state.directory, state.definitions)

  defp commit_reply(reply, state, previous) do
    case persist(state) do
      :ok -> {:reply, reply, state}
      {:error, reason} -> {:reply, {:error, {:durable_store, reason}}, previous}
    end
  end

  defp startable(state, id, %Definition{} = definition) do
    if definition.reserved and runtime(state, id) == nil,
      do: {:error, :cleanup_uncertain},
      else: :ok
  end

  defp certificate_path(state, id),
    do:
      Path.join(
        state.directory,
        "cleanup-" <> Base.url_encode64(:crypto.hash(:sha256, id), padding: false) <> ".etf"
      )

  defp beam_identity,
    do: System.pid() <> ":" <> Integer.to_string(:erlang.system_info(:start_time))

  defp runtime(state, id) do
    case Registry.lookup(VMManager.Registry, {state.identity, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp runtime_status(pid) do
    try do
      {:ok, GenServer.call(pid, :status)}
    catch
      :exit, _ -> :unavailable
    end
  end

  defp stop_runtime(pid) do
    try do
      GenServer.call(pid, :stop, 30_000)
    catch
      :exit, reason -> {:error, {:controller_unavailable, inspect(reason)}}
    end
  end

  defp status(state, id, definition) do
    observed =
      case runtime(state, id) do
        nil ->
          Map.get(
            state.statuses,
            id,
            definition.observed ||
              %Status{
                phase: if(definition.reserved, do: :retained, else: :stopped),
                cleanup: if(definition.reserved, do: :unknown, else: :ok)
              }
          )

        pid ->
          case runtime_status(pid) do
            {:ok, observed} -> %{observed | execution: pid}
            :unavailable -> %Status{phase: :retained, cleanup: :unknown}
          end
      end

    enrich_status(observed, id, definition)
  end

  defp enrich_status(%Status{} = observed, id, %Definition{} = definition) do
    failure = definition.failure || observed.failure
    phase = if failure == :restart_exhausted, do: :failed, else: observed.phase

    execution =
      if phase in [:stopped, :finished, :retained, :failed], do: nil, else: observed.execution

    %{
      observed
      | id: id,
        execution_id: id,
        config: definition.config,
        desired: definition.desired,
        failure: failure,
        phase: phase,
        execution: execution
    }
  end

  defp stopped(state, id) do
    definition = state.definitions[id]
    observed = definition.observed || %Status{}

    if definition.desired == :stopped and not definition.reserved and observed.cleanup == :ok and
         observed.phase in [:stopped, :finished], do: :ok, else: {:error, :vm_not_stopped}
  end

  defp capacity(state, id, %Config{} = config) do
    resources = [
      vms: 1,
      cpus: config.cpus,
      memory: config.memory,
      scratch_bytes: config.scratch_bytes
    ]

    used =
      Enum.reduce(state.definitions, Map.new(resources, fn {key, _} -> {key, 0} end), fn {other,
                                                                                          definition},
                                                                                         totals ->
        if other != id and definition.reserved do
          Enum.reduce(
            [
              vms: 1,
              cpus: definition.config.cpus,
              memory: definition.config.memory,
              scratch_bytes: definition.config.scratch_bytes
            ],
            totals,
            fn {key, value}, acc -> Map.update!(acc, key, &(&1 + value)) end
          )
        else
          totals
        end
      end)

    oversized =
      Enum.find(resources, fn {key, amount} -> amount > Keyword.fetch!(state.budgets, key) end)

    exhausted =
      Enum.find(resources, fn {key, amount} ->
        amount + Map.fetch!(used, key) > Keyword.fetch!(state.budgets, key)
      end)

    case {oversized, exhausted} do
      {{key, _}, _} -> {:error, {:request_exceeds_capacity, key}}
      {nil, {key, _}} -> {:error, {:capacity_exhausted, key}}
      {nil, nil} -> :ok
    end
  end

  defp publish(state, id, %Status{} = observed) do
    if Map.get(state.statuses, id) != observed do
      event = enrich_status(observed, id, Map.fetch!(state.definitions, id))

      Enum.each(
        Map.get(state.subscribers, id, MapSet.new()),
        &send(&1, {:vm_manager, id, event})
      )
    end

    %{state | statuses: Map.put(state.statuses, id, observed)}
  end
end
