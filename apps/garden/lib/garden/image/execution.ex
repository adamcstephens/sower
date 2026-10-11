defmodule Garden.Image.Execution do
  @moduledoc false
  use GenServer
  use TypedStruct
  alias Garden.Image

  typedstruct do
    field :guard, pid(), enforce: true
    field :status, Image.Status.t(), default: %Image.Status{}
    field :waiters, [GenServer.from()], default: []
    field :managed, boolean(), default: false
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
    with %Image{system: "x86_64-linux", contract: 1, vsock_port: 5000} <-
           Keyword.get(options, :image),
         %Image.Command{} = command <- Keyword.get(options, :command),
         :ok <- Image.validate_command(command),
         {:ok, _frame} <- Garden.Image.Protocol.execute(command),
         :ok <- validate(options) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_execution}
    end
  end

  def child_spec(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}
  end

  @impl GenServer
  def init(options) do
    server = self()

    if options[:ledger] do
      :ets.insert(options[:ledger_table], {{:execution, options[:execution_id]}, server})
    end

    guard = spawn(fn -> Garden.Image.Guard.run(server, options) end)
    Process.monitor(guard)
    {:ok, %__MODULE__{guard: guard, managed: Keyword.has_key?(options, :ledger)}}
  end

  @impl GenServer
  def handle_call(:status, _from, %__MODULE__{} = state), do: {:reply, state.status, state}

  def handle_call(:cancel, _from, %__MODULE__{} = state) do
    send(state.guard, {:finish, {:error, :cancelled}})
    {:reply, :ok, state}
  end

  def handle_call(:await, from, %__MODULE__{status: %Image.Status{phase: phase}} = state)
      when phase not in [:finished, :retained] do
    {:noreply, %{state | waiters: [from | state.waiters]}}
  end

  def handle_call(:await, _from, %__MODULE__{} = state), do: {:reply, state.status.result, state}

  @impl GenServer
  def handle_cast(:cancel, %__MODULE__{} = state) do
    send(state.guard, {:finish, {:error, :cancelled}})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info({:image_status, changes}, %__MODULE__{} = state) do
    {:noreply, %{state | status: struct!(state.status, changes)}}
  end

  def handle_info({:image_finished, result, cleanup}, %__MODULE__{} = state) do
    Enum.each(state.waiters, &GenServer.reply(&1, result))
    phase = if cleanup == :ok, do: :finished, else: :retained

    state = %{
      state
      | waiters: [],
        status: %{state.status | phase: phase, result: result, cleanup: cleanup}
    }

    if state.managed, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, guard, reason}, %__MODULE__{guard: guard} = state) do
    if state.status.phase in [:finished, :retained] do
      {:noreply, state}
    else
      handle_info({:image_finished, {:error, {:guard_down, reason}}, :unconfirmed}, state)
    end
  end

  defp validate(options) do
    cond do
      not is_pid(options[:owner]) ->
        {:error, {:invalid_option, :owner}}

      not Enum.all?([:cpus, :memory, :scratch_bytes, :deadline_ms], fn key ->
        value = Keyword.get(options, key, 1)
        is_integer(value) and value > 0
      end) ->
        {:error, :invalid_resource_option}

      not is_function(Keyword.get(options, :on_output, &Garden.Image.IO.output/2), 2) ->
        {:error, {:invalid_option, :on_output}}

      true ->
        :ok
    end
  end
end
