defmodule Garden.DeploymentLog do
  use GenServer
  use TypedStruct

  alias SowerClient.Orchestration.SeedDeploymentLog

  @batch_bytes 16_384
  @pending_bytes 65_536
  @flush_interval 100

  typedstruct do
    field :pid, pid(), enforce: true
    field :pending, :atomics.atomics_ref(), enforce: true
    field :deployment_sid, String.t()
    field :seed_sid, String.t()
    field :send_fun, function()
    field :sequence, non_neg_integer(), default: 0
    field :buffer, binary(), default: ""
    field :timer, reference()
  end

  def start(deployment_sid, seed_sid, opts \\ []) do
    pending = :atomics.new(1, signed: false)
    {:ok, pid} = GenServer.start(__MODULE__, {self(), pending, deployment_sid, seed_sid, opts})
    %__MODULE__{pid: pid, pending: pending}
  end

  # Reserving capacity before sending bounds both the mailbox and the batch buffer.
  # Output is best effort: a busy/disconnected socket never holds up the command.
  def output(%__MODULE__{} = log, line) do
    line =
      line
      |> String.replace_invalid()
      |> then(&Regex.replace(~r/\x1b\[[0-9;]*[a-zA-Z]/, &1, ""))

    enqueue(log, line <> "\n")
  end

  def flush(%__MODULE__{} = log), do: GenServer.call(log.pid, :flush)
  def stop(%__MODULE__{} = log), do: GenServer.stop(log.pid, :normal)

  defp enqueue(_log, ""), do: :ok

  defp enqueue(%__MODULE__{} = log, output) do
    size = boundary(output, min(byte_size(output), @batch_bytes))
    <<chunk::binary-size(^size), rest::binary>> = output

    if :atomics.add_get(log.pending, 1, size) <= @pending_bytes do
      send(log.pid, {:output, :binary.copy(chunk)})
    else
      :atomics.sub(log.pending, 1, size)
    end

    enqueue(log, rest)
  end

  defp boundary(output, size) when size == byte_size(output), do: size

  defp boundary(output, size) do
    if Bitwise.band(:binary.at(output, size), 0xC0) == 0x80,
      do: boundary(output, size - 1),
      else: size
  end

  @impl GenServer
  def init({owner, pending, deployment_sid, seed_sid, opts}) do
    Process.monitor(owner)

    {:ok,
     %__MODULE__{
       pid: self(),
       pending: pending,
       deployment_sid: deployment_sid,
       seed_sid: seed_sid,
       send_fun: Keyword.get(opts, :send_fun, &Garden.Socket.send_deployment_log/1)
     }}
  end

  @impl GenServer
  def handle_info({:output, chunk}, %__MODULE__{} = state) do
    state =
      if byte_size(state.buffer) + byte_size(chunk) > @batch_bytes,
        do: send_batch(state),
        else: state

    state = %{state | buffer: state.buffer <> chunk}

    state =
      if byte_size(state.buffer) == @batch_bytes,
        do: send_batch(state),
        else: state

    state =
      if state.buffer != "" and state.timer == nil,
        do: %{state | timer: Process.send_after(self(), :flush, @flush_interval)},
        else: state

    :atomics.sub(state.pending, 1, byte_size(chunk))
    {:noreply, state}
  end

  def handle_info(:flush, %__MODULE__{} = state) do
    {:noreply, send_batch(%{state | timer: nil})}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_call(:flush, _from, %__MODULE__{} = state) do
    {:reply, :ok, send_batch(state)}
  end

  defp send_batch(%__MODULE__{buffer: ""} = state), do: state

  defp send_batch(%__MODULE__{} = state) do
    sequence = state.sequence + 1

    state.send_fun.(%SeedDeploymentLog{
      deployment_sid: state.deployment_sid,
      seed_sid: state.seed_sid,
      sequence: sequence,
      output: state.buffer
    })

    %{state | sequence: sequence, buffer: ""}
  end
end
