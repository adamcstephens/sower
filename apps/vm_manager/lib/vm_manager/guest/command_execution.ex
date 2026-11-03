defmodule VMManager.Guest.CommandExecution do
  @moduledoc false
  use GenServer
  use TypedStruct

  typedstruct do
    field :vm, pid(), enforce: true
    field :vm_monitor, reference(), enforce: true
    field :caller_monitor, reference(), enforce: true
    field :caller_alive, boolean(), default: true
    field :timer, reference(), enforce: true
    field :status, VMManager.CommandStatus.t(), default: %VMManager.CommandStatus{}
    field :waiters, [GenServer.from()], default: []
  end

  def start(vm, caller, deadline),
    do: GenServer.start(__MODULE__, {vm, caller, deadline})

  @impl GenServer
  def init({vm, caller, deadline}) do
    {:ok,
     %__MODULE__{
       vm: vm,
       vm_monitor: Process.monitor(vm),
       caller_monitor: Process.monitor(caller),
       timer: Process.send_after(self(), :deadline, deadline)
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, %__MODULE__{} = state), do: {:reply, state.status, state}

  def handle_call(
        :await,
        from,
        %__MODULE__{status: %VMManager.CommandStatus{phase: :running}} = state
      ) do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await, _from, %__MODULE__{} = state), do: {:reply, state.status.result, state}

  def handle_call(:cancel, _from, %__MODULE__{} = state) do
    if state.status.phase == :running, do: send(state.vm, {:cancel_command, self(), :cancelled})
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:deadline, %__MODULE__{} = state) do
    if state.status.phase == :running, do: send(state.vm, {:cancel_command, self(), :timeout})
    {:noreply, state}
  end

  def handle_info({:command_finished, result}, %__MODULE__{} = state), do: complete(state, result)

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{vm_monitor: ref} = state) do
    if state.status.phase == :running,
      do: complete(state, {:error, {:vm_down, reason}}),
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{caller_monitor: ref} = state) do
    if state.status.phase == :running do
      send(state.vm, {:cancel_command, self(), :caller_down})
      {:noreply, %{state | caller_alive: false}}
    else
      {:stop, :normal, state}
    end
  end

  defp complete(%__MODULE__{status: %VMManager.CommandStatus{phase: :finished}} = state, _result),
    do: {:noreply, state}

  defp complete(%__MODULE__{} = state, result) do
    Process.cancel_timer(state.timer)
    Process.demonitor(state.vm_monitor, [:flush])
    Enum.each(state.waiters, &GenServer.reply(&1, result))

    state = %{
      state
      | waiters: [],
        status: %VMManager.CommandStatus{phase: :finished, result: result}
    }

    if state.caller_alive, do: {:noreply, state}, else: {:stop, :normal, state}
  end
end
