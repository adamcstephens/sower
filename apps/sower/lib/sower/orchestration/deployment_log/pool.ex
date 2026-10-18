defmodule Sower.Orchestration.DeploymentLog.Pool do
  use GenServer
  use TypedStruct

  alias Sower.Orchestration.Deployment
  alias Sower.Orchestration.DeploymentLog.Buffer

  @timeout 2_000

  typedstruct module: State do
    field :supervisor, GenServer.server(), enforce: true
    field :max_buffers, pos_integer(), default: 64
    field :buffer_opts, keyword(), default: []
    field :owners, map(), default: %{}
    field :order, :queue.queue(), default: :queue.new()
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    server_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  def ensure(%Deployment{} = deployment, pool \\ __MODULE__) do
    case lookup(deployment.org_id, deployment.sid) do
      # Creation must finish before the caller releases the deployment row lock.
      nil -> GenServer.call(pool, {:ensure, deployment}, :infinity)
      pid -> {:ok, pid}
    end
  end

  def lookup(org_id, deployment_sid) do
    case :global.whereis_name({Buffer, org_id, deployment_sid}) do
      :undefined -> nil
      pid -> pid
    end
  end

  def delete(%Deployment{} = deployment) do
    case lookup(deployment.org_id, deployment.sid) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal, @timeout)
    end
  end

  @impl GenServer
  def init(opts) do
    supervisor = Keyword.get(opts, :supervisor, Sower.Orchestration.DeploymentLog.Supervisor)
    max_buffers = Keyword.get(opts, :max_buffers, 64)

    if is_integer(max_buffers) and max_buffers > 0 do
      # The dedicated supervisor can survive a pool crash. Drop those ephemeral
      # owners rather than leaving children outside the new pool's capacity bound.
      for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(supervisor),
          is_pid(pid) do
        DynamicSupervisor.terminate_child(supervisor, pid)
      end

      {:ok,
       %State{
         supervisor: supervisor,
         max_buffers: max_buffers,
         buffer_opts: Keyword.take(opts, [:max_bytes, :max_chunks])
       }}
    else
      {:stop, :invalid_limits}
    end
  end

  @impl GenServer
  def handle_call({:ensure, %Deployment{} = deployment}, _from, %State{} = state) do
    case lookup(deployment.org_id, deployment.sid) do
      nil -> start_owner(deployment, state)
      pid -> {:reply, {:ok, pid}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, pid, _reason}, %State{} = state) do
    if Map.get(state.owners, pid) == ref do
      {:noreply, forget(state, pid)}
    else
      {:noreply, state}
    end
  end

  defp start_owner(%Deployment{} = deployment, %State{} = state) do
    state =
      Enum.reduce(state.owners, state, fn {pid, _ref}, state ->
        if Process.alive?(pid), do: state, else: forget(state, pid)
      end)
      |> make_room()

    opts = Keyword.put(state.buffer_opts, :deployment, deployment)

    case DynamicSupervisor.start_child(state.supervisor, {Buffer, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)

        state = %{
          state
          | owners: Map.put(state.owners, pid, ref),
            order: :queue.in(pid, state.order)
        }

        {:reply, {:ok, pid}, state}

      {:error, {:already_started, pid}} ->
        {:reply, {:ok, pid}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  defp make_room(%State{} = state) when map_size(state.owners) < state.max_buffers, do: state

  defp make_room(%State{} = state) do
    {:value, pid} = :queue.peek(state.order)
    DynamicSupervisor.terminate_child(state.supervisor, pid)
    forget(state, pid)
  end

  defp forget(%State{} = state, pid) do
    {ref, owners} = Map.pop(state.owners, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    %{state | owners: owners, order: :queue.filter(&(&1 != pid), state.order)}
  end
end
