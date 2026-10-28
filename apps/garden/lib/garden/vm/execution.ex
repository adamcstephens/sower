defmodule Garden.VM.Execution do
  @moduledoc false
  use GenServer
  use TypedStruct
  alias Garden.{Image, VM}

  typedstruct do
    field :guard, pid(), enforce: true
    field :status, VM.Status.t(), default: %VM.Status{}
    field :waiters, [GenServer.from()], default: []
    field :ready_waiters, [GenServer.from()], default: []
    field :managed, boolean(), default: false
    field :command_monitor, reference()
    field :command, pid()
    field :options, keyword(), enforce: true
  end

  def start_link(options) do
    options = Keyword.put_new(options, :owner, self())

    with :ok <- validate_options(options) do
      GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_options(options) do
    with %Image{system: "x86_64-linux", contract: contract, vsock_port: 5000}
         when contract in [1, 2] <- Keyword.get(options, :image),
         :ok <- validate_initial_command(options),
         :ok <- validate(options) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_execution}
    end
  end

  def validate_command_options(%VM.Command{} = command, options) do
    with :ok <- VM.validate_command(command),
         {:ok, _frame} <- Garden.VM.Protocol.execute(command),
         true <-
           is_integer(Keyword.get(options, :deadline_ms, 60_000)) and
             Keyword.get(options, :deadline_ms, 60_000) > 0,
         true <- is_function(Keyword.get(options, :on_output, &VM.IO.output/2), 2) do
      :ok
    else
      false -> {:error, :invalid_command_option}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_initial_command(options) do
    case options[:command] do
      %VM.Command{} = command ->
        validate_command_options(command, options)

      nil ->
        if options[:image].contract == 2,
          do: :ok,
          else: {:error, :persistent_guest_contract_required}

      _ ->
        {:error, :invalid_execution}
    end
  end

  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}

  @impl GenServer
  def init(options) do
    server = self()

    if options[:ledger],
      do: :ets.insert(options[:ledger_table], {{:execution, options[:execution_id]}, server})

    guard = spawn(fn -> VM.Guard.run(server, options) end)
    Process.monitor(guard)

    {:ok,
     %__MODULE__{
       guard: guard,
       managed: Keyword.has_key?(options, :ledger),
       options: options,
       status: %VM.Status{
         phase: :booting,
         persistent: options[:command] == nil,
         owner: options[:owner],
         execution: server,
         execution_id: options[:execution_id],
         guard: guard
       }
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, %__MODULE__{} = state), do: {:reply, state.status, state}

  def handle_call(:cancel, _from, %__MODULE__{} = state) do
    send(state.guard, {:finish, {:error, :cancelled}})
    {:reply, :ok, stopping(state)}
  end

  def handle_call(:stop, from, %__MODULE__{} = state) do
    if terminal?(state) do
      {:reply, stop_result(state), state}
    else
      send(state.guard, {:finish, :ok})
      {:noreply, %{stopping(state) | waiters: [{:stop, from} | state.waiters]}}
    end
  end

  def handle_call(:await_ready, from, %__MODULE__{} = state) do
    cond do
      state.status.phase in [:ready, :running_command] ->
        {:reply, {:ok, state.status}, state}

      terminal?(state) or state.status.phase == :stopping ->
        {:reply, {:error, :vm_unavailable}, state}

      true ->
        {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
    end
  end

  def handle_call({:execute, command, options}, {caller, _tag}, %__MODULE__{} = state) do
    cond do
      not state.status.persistent ->
        {:reply, {:error, :disposable_vm}, state}

      state.command != nil ->
        {:reply, {:error, :busy}, state}

      state.status.phase != :ready ->
        {:reply, {:error, :vm_unavailable}, state}

      true ->
        case validate_command_options(command, options) do
          :ok ->
            {handle, state} = begin_command(state, command, options, caller)
            {:reply, {:ok, handle}, state}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call(:await, from, %__MODULE__{} = state) do
    if terminal?(state),
      do: {:reply, state.status.result, state},
      else: {:noreply, %{state | waiters: [{:await, from} | state.waiters]}}
  end

  @impl GenServer
  def handle_cast({:finish, result}, %__MODULE__{} = state) do
    send(state.guard, {:finish, result})
    {:noreply, stopping(state)}
  end

  @impl GenServer
  def handle_info({:vm_status, changes}, %__MODULE__{} = state) do
    changes =
      if state.status.phase == :stopping, do: Keyword.delete(changes, :phase), else: changes

    state = %{state | status: struct!(state.status, changes)}

    if state.status.phase == :ready do
      Enum.each(state.ready_waiters, &GenServer.reply(&1, {:ok, state.status}))
      state = %{state | ready_waiters: []}

      if state.options[:command] && state.command == nil do
        {_handle, state} =
          begin_command(state, state.options[:command], state.options, state.options[:owner])

        {:noreply, state}
      else
        {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:cancel_command, command, reason}, %__MODULE__{command: command} = state) do
    send(state.guard, {:cancel_command, command, reason})
    {:noreply, state}
  end

  def handle_info({:cancel_command, _command, _reason}, %__MODULE__{} = state),
    do: {:noreply, state}

  def handle_info({:command_finished, command, result}, %__MODULE__{command: command} = state) do
    Process.demonitor(state.command_monitor, [:flush])
    send(command, {:command_finished, result})
    phase = if state.status.phase == :stopping, do: :stopping, else: :ready

    {:noreply,
     %{state | command: nil, command_monitor: nil, status: %{state.status | phase: phase}}}
  end

  def handle_info({:vm_finished, result, cleanup}, %__MODULE__{} = state) do
    if state.command_monitor, do: Process.demonitor(state.command_monitor, [:flush])

    if state.command,
      do:
        send(
          state.command,
          {:command_finished, if(result == :ok, do: {:error, :vm_stopped}, else: result)}
        )

    phase =
      cond do
        cleanup != :ok -> :retained
        state.status.persistent -> :stopped
        true -> :finished
      end

    state = %{
      state
      | command: nil,
        command_monitor: nil,
        status: %{state.status | phase: phase, result: result, cleanup: cleanup}
    }

    Enum.each(state.ready_waiters, &GenServer.reply(&1, {:error, {:boot_failed, result}}))

    Enum.each(state.waiters, fn {kind, from} ->
      GenServer.reply(from, if(kind == :stop, do: stop_result(state), else: result))
    end)

    state = %{state | waiters: [], ready_waiters: []}
    if state.managed, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, command, _reason},
        %__MODULE__{command_monitor: ref, command: command} = state
      )
      when not is_nil(command) do
    send(state.guard, {:cancel_command, command, :command_handle_down})
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, guard, reason}, %__MODULE__{guard: guard} = state) do
    if terminal?(state),
      do: {:noreply, state},
      else: handle_info({:vm_finished, {:error, {:guard_down, reason}}, :unconfirmed}, state)
  end

  defp begin_command(%__MODULE__{} = state, command, options, caller) do
    {:ok, handle} =
      VM.CommandExecution.start(
        self(),
        caller,
        Keyword.get(options, :deadline_ms, 60_000),
        state.status.persistent
      )

    send(
      state.guard,
      {:execute, handle, command, Keyword.get(options, :on_output, &VM.IO.output/2)}
    )

    phase = if state.status.persistent, do: :running_command, else: :running

    {handle,
     %{
       state
       | command: handle,
         command_monitor: Process.monitor(handle),
         status: %{state.status | phase: phase}
     }}
  end

  defp stopping(%__MODULE__{} = state),
    do:
      if(terminal?(state), do: state, else: %{state | status: %{state.status | phase: :stopping}})

  defp terminal?(%__MODULE__{} = state),
    do: state.status.phase in [:finished, :stopped, :retained]

  defp stop_result(%__MODULE__{status: %VM.Status{cleanup: :ok}}), do: :ok
  defp stop_result(%__MODULE__{} = state), do: state.status.result

  defp validate(options) do
    cond do
      Keyword.get(options, :network, :none) not in [:none, :full] ->
        {:error, {:invalid_option, :network}}

      Keyword.get(options, :network, :none) == :full and options[:image].network_config != :static ->
        {:error, :unsupported_network_config}

      not is_pid(options[:owner]) ->
        {:error, {:invalid_option, :owner}}

      not Enum.all?([:cpus, :memory, :scratch_bytes, :deadline_ms, :boot_deadline_ms], fn key ->
        value = Keyword.get(options, key, 1)
        is_integer(value) and value > 0
      end) ->
        {:error, :invalid_resource_option}

      not is_function(Keyword.get(options, :on_output, &VM.IO.output/2), 2) ->
        {:error, {:invalid_option, :on_output}}

      true ->
        :ok
    end
  end
end
