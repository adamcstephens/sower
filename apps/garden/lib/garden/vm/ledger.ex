defmodule Garden.VM.Ledger do
  @moduledoc false
  use GenServer
  use TypedStruct
  alias Garden.VM

  @dimensions [:vms, :cpus, :memory, :scratch_bytes]
  @defaults [vms: 1, cpus: 1, memory: 536_870_912, scratch_bytes: 4_294_967_296]

  typedstruct module: Entry do
    field :status, VM.Status.t(), enforce: true
    field :resources, keyword(), enforce: true
    field :reserved, boolean(), default: true
    field :waiters, [GenServer.from()], default: []
  end

  typedstruct do
    field :table, term(), enforce: true
    field :budgets, keyword(), enforce: true
    field :result_limit, non_neg_integer(), default: 128
    field :shutdown_ms, pos_integer(), default: 15_000
    field :activator_socket, String.t(), default: "/run/sower-activator/activator.sock"
    field :entries, map(), default: %{}
    field :clean_order, term(), default: {[], []}
    field :manager, pid()
    field :supervisor, pid()
    field :parent, pid()
    field :monitors, map(), default: %{}
    field :mode, atom(), default: :recovering
    field :shutdown_waiters, [GenServer.from()], default: []
    field :shutdown_timer, reference()
  end

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @impl GenServer
  def init(options) do
    table = Garden.VM.Ledger.Store.table(Keyword.fetch!(options, :name))
    :ets.insert(table, {:identity, Keyword.fetch!(options, :name)})
    budgets = Keyword.get(options, :budgets, @defaults)
    limit = Keyword.get(options, :result_limit, 128)
    deadline = Keyword.get(options, :shutdown_ms, 15_000)

    if Enum.all?(@dimensions, &(is_integer(budgets[&1]) and budgets[&1] > 0)) and
         is_integer(limit) and limit >= 0 and is_integer(deadline) and deadline > 0 do
      state =
        case :ets.lookup(table, :state) do
          [] ->
            %__MODULE__{table: table, budgets: budgets}

          [{:state, previous}] ->
            %{previous | monitors: %{}, mode: :recovering, shutdown_timer: nil}
        end

      state = %{
        state
        | budgets: budgets,
          result_limit: limit,
          shutdown_ms: deadline,
          activator_socket:
            Keyword.get(options, :activator_socket) || "/run/sower-activator/activator.sock",
          parent: Keyword.fetch!(options, :parent)
      }

      state = monitor(state, state.parent, :parent)
      state = state |> monitor(state.manager, :manager) |> monitor(state.supervisor, :supervisor)
      state = evict(state)

      state =
        Enum.reduce(Map.keys(state.entries), state, fn id, state ->
          case Map.get(state.entries, id) do
            nil ->
              state

            entry ->
              guard =
                case :ets.lookup(table, {:guard, id}) do
                  [{_, pid}] -> pid
                  [] -> entry.status.guard
                end

              execution =
                case :ets.lookup(table, {:execution, id}) do
                  [{_, pid}] -> pid
                  [] -> entry.status.execution
                end

              entry = %{entry | status: %{entry.status | guard: guard, execution: execution}}
              entry = recover_status(table, id, entry)
              state = %{state | entries: Map.put(state.entries, id, entry)}

              state =
                state
                |> monitor(entry.status.execution, {:execution, id})
                |> monitor(guard, {:guard, id})

              certificate(state, id)
          end
        end)

      {:ok, persist(settle(drain(state)))}
    else
      {:stop, :invalid_manager_options}
    end
  end

  @impl GenServer
  def handle_call({:attach_manager, pid}, _from, %__MODULE__{} = state) do
    state =
      if state.manager && state.manager != pid,
        do: drain(%{state | mode: recovery_mode(state)}),
        else: state

    reply(:ok, state |> Map.put(:manager, pid) |> monitor(pid, :manager) |> settle())
  end

  def handle_call({:attach_supervisor, pid}, _from, %__MODULE__{} = state) do
    state =
      if state.supervisor && state.supervisor != pid,
        do: drain(%{state | mode: recovery_mode(state)}),
        else: state

    reply(:ok, state |> Map.put(:supervisor, pid) |> monitor(pid, :supervisor) |> settle())
  end

  def handle_call({:start, _options}, _from, %__MODULE__{mode: mode} = state) when mode != :open,
    do: reply({:error, :draining}, state)

  def handle_call({:start, options}, _from, %__MODULE__{} = state) do
    options =
      Keyword.merge(
        [
          cpus: 1,
          memory: 536_870_912,
          scratch_bytes: 4_294_967_296,
          deadline_ms: 60_000,
          activator_socket: state.activator_socket
        ],
        options
      )

    resources = Keyword.take(options, [:cpus, :memory, :scratch_bytes]) |> Keyword.put(:vms, 1)

    with :ok <- VM.Execution.validate_options(options),
         :ok <- capacity(state, resources) do
      id = System.unique_integer([:positive, :monotonic])
      status = %VM.Status{execution_id: id, owner: options[:owner]}
      entry = %Entry{status: status, resources: resources}
      state = persist(%{state | entries: Map.put(state.entries, id, entry)})

      options =
        Keyword.merge(options,
          ledger: ledger_identity(state),
          ledger_table: state.table,
          execution_id: id
        )

      case DynamicSupervisor.start_child(state.supervisor, {VM.Execution, options}) do
        {:ok, execution} ->
          entry = %{entry | status: %{status | execution: execution}}

          state =
            %{state | entries: Map.put(state.entries, id, entry)}
            |> monitor(execution, {:execution, id})

          reply({:ok, id}, state)

        {:error, reason} ->
          reply({:error, reason}, %{state | entries: Map.delete(state.entries, id)})
      end
    else
      {:error, reason} -> reply({:error, reason}, state)
    end
  end

  def handle_call(:list, _from, %__MODULE__{} = state) do
    statuses =
      state.entries
      |> Enum.map(fn {_id, entry} -> entry.status end)
      |> Enum.sort_by(& &1.execution_id)

    {:reply, {:ok, statuses}, state}
  end

  def handle_call({:status, id}, _from, %__MODULE__{} = state) do
    result =
      case Map.fetch(state.entries, id) do
        {:ok, entry} -> {:ok, entry.status}
        :error -> {:error, :not_found}
      end

    reply(result, state)
  end

  def handle_call({:cancel, id}, _from, %__MODULE__{} = state) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        if active?(entry), do: cancel_entry(entry)
        reply(:ok, state)

      :error ->
        reply({:error, :not_found}, state)
    end
  end

  def handle_call({:await, id}, from, %__MODULE__{} = state) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        if active?(entry) do
          entry = %{entry | waiters: [from | entry.waiters]}
          noreply(%{state | entries: Map.put(state.entries, id, entry)})
        else
          reply(entry.status.result, state)
        end

      :error ->
        reply({:error, :not_found}, state)
    end
  end

  def handle_call({:guard_started, id, guard}, _from, %__MODULE__{} = state) do
    case Map.fetch(state.entries, id) do
      {:ok, entry} ->
        entry = %{entry | status: %{entry.status | guard: guard}}

        state =
          %{state | entries: Map.put(state.entries, id, entry)} |> monitor(guard, {:guard, id})

        result =
          if state.mode == :open and active?(entry),
            do: :ok,
            else: {:cancel, {:error, :cancelled}}

        reply(result, state)

      :error ->
        reply({:cancel, {:error, :cancelled}}, state)
    end
  end

  def handle_call({:finished, id, guard, result, cleanup}, _from, %__MODULE__{} = state) do
    reply(:ok, complete(state, id, guard, result, cleanup))
  end

  def handle_call(:shutdown, from, %__MODULE__{} = state) do
    state = drain(%{state | mode: :shutdown, shutdown_waiters: [from | state.shutdown_waiters]})

    state =
      if state.shutdown_timer,
        do: state,
        else: %{
          state
          | shutdown_timer: Process.send_after(self(), :shutdown_deadline, state.shutdown_ms)
        }

    noreply(settle(state))
  end

  @impl GenServer
  def handle_cast({:status, id, guard, changes}, %__MODULE__{} = state) do
    case Map.fetch(state.entries, id) do
      {:ok, %Entry{status: %VM.Status{guard: ^guard}} = entry} ->
        if active?(entry) do
          entry = %{entry | status: struct!(entry.status, changes)}
          noreply(%{state | entries: Map.put(state.entries, id, entry)})
        else
          noreply(state)
        end

      _ ->
        noreply(state)
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{} = state) do
    {kind, monitors} = Map.pop(state.monitors, ref)
    state = %{state | monitors: monitors}

    state =
      case kind do
        :manager ->
          drain(%{state | mode: recovery_mode(state), manager: nil})

        :supervisor ->
          drain(%{state | mode: recovery_mode(state), supervisor: nil})

        :parent ->
          drain(%{state | mode: recovery_mode(state), parent: nil})

        {:execution, id} ->
          case Map.get(state.entries, id) do
            %Entry{} = entry ->
              if active?(entry) and entry.status.guard,
                do: send(entry.status.guard, {:finish, {:error, :owner_down}})

              state

            nil ->
              state
          end

        {:guard, id} ->
          case Map.get(state.entries, id) do
            %Entry{} ->
              state = certificate(state, id)
              entry = Map.get(state.entries, id)

              if entry && active?(entry) do
                entry = recover_status(state.table, id, entry)
                state = %{state | entries: Map.put(state.entries, id, entry)}

                result =
                  {:error,
                   {:cleanup_unconfirmed, {:error, {:guard_down, reason}}, :unconfirmed,
                    entry.status.directory}}

                complete(state, id, entry.status.guard, result, :unconfirmed)
              else
                state
              end

            nil ->
              state
          end

        _ ->
          state
      end

    noreply(settle(state))
  end

  def handle_info(:shutdown_deadline, %__MODULE__{} = state) do
    Enum.each(state.shutdown_waiters, &GenServer.reply(&1, shutdown_result(state)))
    noreply(%{state | shutdown_waiters: [], shutdown_timer: nil})
  end

  defp ledger_identity(%__MODULE__{} = state), do: :ets.lookup_element(state.table, :identity, 2)

  defp capacity(%__MODULE__{} = state, resources) do
    oversized = Enum.find(@dimensions, &(resources[&1] > state.budgets[&1]))

    exhausted =
      Enum.find(@dimensions, fn dimension ->
        used =
          Enum.reduce(state.entries, 0, fn {_id, entry}, total ->
            if entry.reserved, do: total + entry.resources[dimension], else: total
          end)

        used + resources[dimension] > state.budgets[dimension]
      end)

    cond do
      oversized -> {:error, {:request_exceeds_capacity, oversized}}
      exhausted -> {:error, {:capacity_exhausted, exhausted}}
      true -> :ok
    end
  end

  defp complete(%__MODULE__{} = state, id, guard, result, cleanup) do
    case Map.get(state.entries, id) do
      %Entry{status: %VM.Status{guard: ^guard}} = entry ->
        if active?(entry) do
          status = %{
            entry.status
            | phase: if(cleanup == :ok, do: :finished, else: :retained),
              result: result,
              cleanup: cleanup
          }

          waiters = entry.waiters
          entry = %{entry | status: status, reserved: cleanup != :ok, waiters: []}
          state = %{state | entries: Map.put(state.entries, id, entry)}

          state =
            if cleanup == :ok,
              do: %{state | clean_order: :queue.in(id, state.clean_order)},
              else: state

          state = state |> evict() |> persist()
          Enum.each(waiters, &GenServer.reply(&1, result))
          settle(state)
        else
          state
        end

      _ ->
        state
    end
  end

  defp evict(%__MODULE__{} = state) do
    if :queue.len(state.clean_order) > state.result_limit do
      {{:value, id}, order} = :queue.out(state.clean_order)
      state = persist(%{state | entries: Map.delete(state.entries, id), clean_order: order})
      :ets.delete(state.table, {:guard, id})
      :ets.delete(state.table, {:terminal, id})
      :ets.delete(state.table, {:execution, id})
      :ets.match_delete(state.table, {{:status, id, :_}, :_})
      evict(state)
    else
      state
    end
  end

  defp certificate(%__MODULE__{} = state, id) do
    case :ets.lookup(state.table, {:terminal, id}) do
      [{_, guard, result, cleanup, directory}] ->
        entry = Map.fetch!(state.entries, id)
        entry = %{entry | status: %{entry.status | directory: directory}}

        complete(
          %{state | entries: Map.put(state.entries, id, entry)},
          id,
          guard,
          result,
          cleanup
        )

      [] ->
        state
    end
  end

  defp recover_status(table, id, %Entry{} = entry) do
    if active?(entry) do
      changes =
        for {{:status, ^id, key}, value} <- :ets.match_object(table, {{:status, id, :_}, :_}),
            do: {key, value}

      %{entry | status: struct!(entry.status, changes)}
    else
      entry
    end
  end

  defp active?(%Entry{} = entry), do: entry.status.phase not in [:finished, :retained]
  defp recovery_mode(%__MODULE__{mode: :shutdown}), do: :shutdown
  defp recovery_mode(%__MODULE__{}), do: :recovering

  defp cancel_entry(%Entry{} = entry, result \\ {:error, :cancelled}) do
    cond do
      entry.status.guard -> send(entry.status.guard, {:finish, result})
      entry.status.execution -> GenServer.cast(entry.status.execution, :cancel)
      true -> :ok
    end
  end

  defp drain(%__MODULE__{} = state) do
    result = if state.mode == :shutdown, do: {:error, :cancelled}, else: {:error, :owner_down}

    Enum.each(state.entries, fn {_id, entry} ->
      if active?(entry), do: cancel_entry(entry, result)
    end)

    state
  end

  defp settle(%__MODULE__{} = state) do
    active = Enum.any?(state.entries, fn {_id, entry} -> active?(entry) end)

    cond do
      active ->
        state

      state.mode == :shutdown ->
        Enum.each(state.shutdown_waiters, &GenServer.reply(&1, shutdown_result(state)))
        if state.shutdown_timer, do: Process.cancel_timer(state.shutdown_timer)
        %{state | shutdown_waiters: [], shutdown_timer: nil}

      state.mode == :recovering and is_pid(state.manager) and is_pid(state.supervisor) and
        Process.alive?(state.manager) and Process.alive?(state.supervisor) and
        is_pid(state.parent) and Process.alive?(state.parent) ->
        %{state | mode: :open}

      true ->
        state
    end
  end

  defp shutdown_result(%__MODULE__{} = state) do
    incomplete =
      Enum.flat_map(state.entries, fn {id, entry} ->
        if entry.reserved,
          do: [{id, entry.status.cleanup || :pending, entry.status.directory}],
          else: []
      end)

    if incomplete == [], do: :ok, else: {:error, {:cleanup_incomplete, Enum.sort(incomplete)}}
  end

  defp monitor(%__MODULE__{} = state, nil, _kind), do: state

  defp monitor(%__MODULE__{} = state, pid, kind) do
    monitors =
      Enum.reduce(state.monitors, state.monitors, fn {ref, existing}, monitors ->
        if existing == kind do
          Process.demonitor(ref, [:flush])
          Map.delete(monitors, ref)
        else
          monitors
        end
      end)

    %{state | monitors: Map.put(monitors, Process.monitor(pid), kind)}
  end

  defp persist(%__MODULE__{} = state) do
    :ets.insert(state.table, {:state, state})
    state
  end

  defp reply(result, %__MODULE__{} = state), do: {:reply, result, persist(state)}
  defp noreply(%__MODULE__{} = state), do: {:noreply, persist(state)}
end
