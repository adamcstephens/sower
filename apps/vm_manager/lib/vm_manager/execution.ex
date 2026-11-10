defmodule VMManager.Execution do
  @moduledoc """
  Controls one VM attempt and exposes its observed status to the manager.

  A separate guard owns the attempt's resource lifecycle. This server forwards
  stop and command requests, tracks readiness and resolves waiters. It reports
  retained state when the guard cannot confirm cleanup.
  """
  use GenServer
  use TypedStruct
  alias VMManager, as: VM

  typedstruct do
    field :guard, pid(), enforce: true
    field :session, pid()
    field :status, VM.Status.t(), default: %VM.Status{}
    field :waiters, [GenServer.from()], default: []
    field :ready_waiters, [GenServer.from()], default: []
    field :running_waiters, [GenServer.from()], default: []
    field :options, keyword(), enforce: true
  end

  def start_link(options) do
    options = Keyword.put_new(options, :owner, self())

    with :ok <- validate_options(options) do
      GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))
    else
      error -> error
    end
  end

  def validate_options(options) do
    with %VM.Config{} = config <- options[:config],
         :ok <- VM.Config.validate(config),
         true <- is_pid(options[:owner]) do
      :ok
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_execution}
    end
  end

  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}

  @impl GenServer
  def init(options) do
    server = self()
    guard = spawn(fn -> VM.Guard.run(server, options) end)
    Process.monitor(guard)
    guest = options[:config].guest
    persistent = guest == :none or guest.contract == 2

    {:ok,
     %__MODULE__{
       guard: guard,
       options: options,
       status: %VM.Status{
         id: options[:execution_id],
         config: options[:config],
         cleanup: :pending,
         phase: :booting,
         persistent: persistent,
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

  def handle_call({:stop, %VM.Stop{} = policy}, from, %__MODULE__{} = state) do
    if terminal?(state) do
      {:reply, stop_result(state), state}
    else
      send(state.guard, {:stop, policy})
      {:noreply, %{stopping(state) | waiters: [{:stop, from} | state.waiters]}}
    end
  end

  def handle_call(:await_ready, from, %__MODULE__{} = state) do
    cond do
      state.options[:config].guest == :none ->
        {:reply, {:error, :guest_agent_disabled}, state}

      state.status.phase in [:ready, :running_command] ->
        {:reply, {:ok, state.status}, state}

      terminal?(state) or state.status.phase == :stopping ->
        {:reply, {:error, :vm_unavailable}, state}

      true ->
        {:noreply, %{state | ready_waiters: [from | state.ready_waiters]}}
    end
  end

  def handle_call(:await_running, from, %__MODULE__{} = state) do
    cond do
      terminal?(state) or state.status.phase == :stopping ->
        {:reply, {:error, :vm_unavailable}, state}

      state.status.running ->
        {:reply, {:ok, state.status}, state}

      true ->
        {:noreply, %{state | running_waiters: [from | state.running_waiters]}}
    end
  end

  def handle_call({:execute, command, options}, {caller, _}, %__MODULE__{} = state) do
    result =
      cond do
        state.options[:config].guest == :none -> {:error, :guest_agent_disabled}
        state.status.phase not in [:ready, :running_command] -> {:error, :vm_unavailable}
        true -> GenServer.call(state.session, {:execute, command, options, caller}, :infinity)
      end

    {:reply, result, state}
  end

  def handle_call(:await, from, %__MODULE__{} = state) do
    if terminal?(state),
      do: {:reply, state.status.result, state},
      else: {:noreply, %{state | waiters: [{:await, from} | state.waiters]}}
  end

  @impl GenServer
  def handle_cast({:stop, %VM.Stop{} = policy}, %__MODULE__{} = state) do
    send(state.guard, {:stop, policy})
    {:noreply, stopping(state)}
  end

  def handle_cast({:finish, result}, %__MODULE__{} = state) do
    send(state.guard, {:finish, result})
    {:noreply, stopping(state)}
  end

  @impl GenServer
  def handle_info({:guest_session, session}, %__MODULE__{} = state),
    do: {:noreply, %{state | session: session}}

  def handle_info({:vm_status, changes}, %__MODULE__{} = state) do
    changes =
      if state.status.phase == :stopping or terminal?(state),
        do: Keyword.drop(changes, [:phase, :running]),
        else: changes

    state = %{state | status: struct!(state.status, changes)}

    state =
      if state.status.running and state.status.phase != :stopping and not terminal?(state) do
        Enum.each(state.running_waiters, &GenServer.reply(&1, {:ok, state.status}))
        %{state | running_waiters: []}
      else
        state
      end

    state =
      if state.status.phase == :ready do
        Enum.each(state.ready_waiters, &GenServer.reply(&1, {:ok, state.status}))
        %{state | ready_waiters: []}
      else
        state
      end

    {:noreply, state}
  end

  def handle_info({:vm_finished, result, cleanup}, %__MODULE__{} = state) do
    phase =
      cond do
        cleanup != :ok -> :retained
        state.status.persistent -> :stopped
        true -> :finished
      end

    state = %{
      state
      | status: %{state.status | phase: phase, running: false, result: result, cleanup: cleanup}
    }

    Enum.each(
      state.ready_waiters ++ state.running_waiters,
      &GenServer.reply(&1, {:error, {:boot_failed, result}})
    )

    Enum.each(state.waiters, fn {kind, from} ->
      GenServer.reply(from, if(kind == :stop, do: stop_result(state), else: result))
    end)

    {:noreply, %{state | waiters: [], ready_waiters: [], running_waiters: []}}
  end

  def handle_info({:DOWN, _, :process, guard, reason}, %__MODULE__{guard: guard} = state) do
    if terminal?(state),
      do: {:noreply, state},
      else: handle_info({:vm_finished, {:error, {:guard_down, reason}}, :unconfirmed}, state)
  end

  defp stopping(%__MODULE__{} = state) do
    if terminal?(state) do
      state
    else
      Enum.each(state.running_waiters, &GenServer.reply(&1, {:error, :vm_unavailable}))
      %{state | running_waiters: [], status: %{state.status | phase: :stopping}}
    end
  end

  defp terminal?(%__MODULE__{} = state),
    do: state.status.phase in [:finished, :stopped, :retained]

  defp stop_result(%__MODULE__{status: %VM.Status{cleanup: :ok}}), do: :ok
  defp stop_result(%__MODULE__{} = state), do: state.status.result
end
