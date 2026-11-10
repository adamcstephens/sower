defmodule VMManager.Guest.Session do
  @moduledoc """
  Coordinates guest readiness and command execution for one VM attempt.

  Only one command can be active at a time. The session owns its IO worker and
  command handle, forwards status to the execution controller and asks the
  guard to tear down when communication or command cleanup cannot be confirmed.
  Contract 1 ends the VM after a command; contract 2 returns to ready.
  """
  use GenServer
  use TypedStruct
  alias VMManager.Guest.{CommandExecution, IO, Protocol}

  typedstruct do
    field :guard, pid()
    field :execution, pid()
    field :io, pid()
    field :command, pid()
    field :monitor, reference()
    field :cancel_timer, reference()
    field :options, keyword()
    field :ready, boolean(), default: false
    field :terminal, boolean(), default: false
    field :outcome, term(), default: {:error, :vm_stopped}
  end

  def start(guard, execution, path, options, started) do
    GenServer.start(__MODULE__, {guard, execution, path, options, started})
  end

  def validate_command(command, options) do
    with :ok <- VMManager.validate_command(command),
         {:ok, _} <- Protocol.execute(command),
         true <-
           is_integer(Keyword.get(options, :deadline_ms, 60_000)) and
             Keyword.get(options, :deadline_ms, 60_000) > 0,
         true <- is_function(Keyword.get(options, :on_output, &IO.output/2), 2) do
      :ok
    else
      false -> {:error, :invalid_command_option}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl GenServer
  def init({guard, execution, path, options, started}) do
    Process.monitor(guard)
    session = self()
    send(execution, {:guest_session, session})
    guest = options[:config].guest

    {io, _} =
      spawn_monitor(fn -> IO.run(session, path, guest.contract, started, guest.vsock_port) end)

    {:ok, %__MODULE__{guard: guard, execution: execution, io: io, options: options}}
  end

  @impl GenServer
  def handle_call(:quiesce, _from, %__MODULE__{} = state) do
    if state.io, do: Process.exit(state.io, :kill)
    {:reply, :ok, %{state | io: nil, ready: false, terminal: true}}
  end

  def handle_call({:finish, result}, _from, %__MODULE__{} = state) do
    result = if result == :ok or match?({:ok, _}, result), do: {:error, :vm_stopped}, else: result
    {:stop, :normal, :ok, %{state | outcome: result}}
  end

  def handle_call({:execute, command, options, caller}, _from, %__MODULE__{} = state) do
    cond do
      state.terminal ->
        {:reply, {:error, :vm_unavailable}, state}

      state.command != nil ->
        {:reply, {:error, :busy}, state}

      not state.ready ->
        {:reply, {:error, :vm_unavailable}, state}

      true ->
        case validate_command(command, options) do
          :ok ->
            {:ok, handle} =
              CommandExecution.start(
                self(),
                caller,
                Keyword.get(options, :deadline_ms, 60_000)
              )

            send(
              state.io,
              {:execute, handle, command, Keyword.get(options, :on_output, &IO.output/2)}
            )

            send(state.execution, {:vm_status, [phase: :running_command]})

            {:reply, {:ok, handle}, %{state | command: handle, monitor: Process.monitor(handle)}}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl GenServer
  def handle_info({:guest_ready, _elapsed}, %__MODULE__{terminal: true} = state),
    do: {:noreply, state}

  def handle_info({:guest_ready, elapsed}, %__MODULE__{} = state) do
    send(state.guard, {:guest_ready, elapsed})
    send(state.execution, {:vm_status, [phase: :ready]})
    {:noreply, %{state | ready: true}}
  end

  def handle_info({:guest_reconnecting, _command}, %__MODULE__{terminal: true} = state),
    do: {:noreply, state}

  def handle_info({:guest_reconnecting, command}, %__MODULE__{} = state),
    do: cancel_deadline(state, command)

  def handle_info({:cancel_command, _command, _reason}, %__MODULE__{terminal: true} = state),
    do: {:noreply, state}

  def handle_info({:cancel_command, command, reason}, %__MODULE__{command: command} = state) do
    send(state.io, {:cancel, command, reason})
    cancel_deadline(state, command)
  end

  def handle_info({:cancel_deadline, command}, %__MODULE__{command: command} = state)
      when not is_nil(command) do
    teardown(state, {:error, :command_cleanup_unconfirmed})
  end

  def handle_info({:command_finished, command, result}, %__MODULE__{command: command} = state) do
    Process.demonitor(state.monitor, [:flush])
    if state.cancel_timer, do: Process.cancel_timer(state.cancel_timer)
    send(command, {:command_finished, result})

    state = %{state | command: nil, monitor: nil, cancel_timer: nil}

    cond do
      state.terminal ->
        {:noreply, state}

      state.options[:config].guest.contract == 1 ->
        teardown(state, result)

      true ->
        send(state.execution, {:vm_status, [phase: :ready]})
        {:noreply, state}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, command, _},
        %__MODULE__{monitor: ref, command: command} = state
      )
      when not is_nil(command),
      do: handle_info({:cancel_command, command, :command_handle_down}, state)

  def handle_info({:DOWN, _, :process, io, reason}, %__MODULE__{io: io} = state) do
    teardown(state, {:error, {:io_down, reason}})
  end

  def handle_info({:DOWN, _, :process, guard, _}, %__MODULE__{guard: guard} = state),
    do: {:stop, :normal, state}

  def handle_info({:finish, result}, %__MODULE__{} = state), do: teardown(state, result)

  def handle_info(_, %__MODULE__{} = state), do: {:noreply, state}

  @impl GenServer
  def terminate(_, %__MODULE__{} = state) do
    if state.io, do: Process.exit(state.io, :kill)
    if state.command, do: send(state.command, {:command_finished, state.outcome})
    :ok
  end

  defp cancel_deadline(%__MODULE__{} = state, command) do
    timer = state.cancel_timer || Process.send_after(self(), {:cancel_deadline, command}, 5_000)
    {:noreply, %{state | cancel_timer: timer}}
  end

  defp teardown(%__MODULE__{terminal: true} = state, _result), do: {:noreply, state}

  defp teardown(%__MODULE__{} = state, result) do
    send(state.guard, {:finish, result})
    {:noreply, %{state | terminal: true, ready: false}}
  end
end
