defmodule Sower.Orchestration.DeploymentLog.Buffer do
  use GenServer, restart: :temporary, shutdown: 2_000
  use TypedStruct

  alias Sower.Orchestration.{Deployment, DeploymentLog, DeploymentPubSub, Garden, Seed}
  alias SowerClient.Orchestration.SeedDeploymentLog

  @timeout 2_000

  typedstruct module: State do
    field :deployment, Deployment.t(), enforce: true
    field :seeds_by_sid, map(), enforce: true
    field :table, :ets.tid(), enforce: true
    field :max_bytes, pos_integer(), default: 1_048_576
    field :max_chunks, pos_integer(), default: 1024
    field :bytes, non_neg_integer(), default: 0
    field :count, non_neg_integer(), default: 0
    field :order, :queue.queue(), default: :queue.new()
    field :evicted_through, map(), default: %{}
    field :reset?, boolean(), default: true
  end

  def start_link(opts) do
    deployment = Keyword.fetch!(opts, :deployment)
    name = {__MODULE__, deployment.org_id, deployment.sid}
    GenServer.start_link(__MODULE__, opts, name: {:global, name})
  end

  def append(pid, %SeedDeploymentLog{} = request, %Garden{} = garden) do
    GenServer.call(pid, {:append, request, garden}, @timeout)
  end

  def list(pid), do: GenServer.call(pid, :list, @timeout)

  @impl GenServer
  def init(opts) do
    %Deployment{} = deployment = Keyword.fetch!(opts, :deployment)
    max_bytes = Keyword.get(opts, :max_bytes, 1_048_576)
    max_chunks = Keyword.get(opts, :max_chunks, 1024)

    if is_integer(max_bytes) and max_bytes > 0 and is_integer(max_chunks) and max_chunks > 0 do
      seeds_by_sid = Map.new(deployment.seeds, fn %Seed{} = seed -> {seed.sid, seed} end)

      {:ok,
       %State{
         deployment: deployment,
         seeds_by_sid: seeds_by_sid,
         table: :ets.new(__MODULE__, [:ordered_set, :private]),
         max_bytes: max_bytes,
         max_chunks: max_chunks
       }}
    else
      {:stop, :invalid_limits}
    end
  end

  @impl GenServer
  def handle_call(:list, _from, %State{} = state) do
    chunks = :ets.foldr(fn {_key, chunk}, chunks -> [chunk | chunks] end, [], state.table)
    {:reply, chunks, state}
  end

  def handle_call(
        {:append, %SeedDeploymentLog{} = request, %Garden{} = garden},
        _from,
        %State{} = state
      ) do
    case authorize(request, garden, state) do
      :ok -> insert(request, state)
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp authorize(%SeedDeploymentLog{} = request, %Garden{} = garden, %State{} = state) do
    deployment = state.deployment

    cond do
      not valid_chunk?(request) ->
        {:error, :invalid_log_chunk}

      garden.org_id != deployment.org_id or garden.id != deployment.garden_id or
          request.deployment_sid != deployment.sid ->
        {:error, :unauthorized}

      deployment.state in [:completed, :stale, :canceled] ->
        {:error, :deployment_terminal}

      not Map.has_key?(state.seeds_by_sid, request.seed_sid) ->
        {:error, :seed_not_in_deployment}

      true ->
        :ok
    end
  end

  defp valid_chunk?(%SeedDeploymentLog{} = request)
       when is_integer(request.sequence) and request.sequence > 0 and is_binary(request.output) and
              byte_size(request.output) <= 16_384 do
    String.valid?(request.output)
  end

  defp valid_chunk?(%SeedDeploymentLog{}), do: false

  defp insert(%SeedDeploymentLog{} = request, %State{} = state) do
    seed = Map.fetch!(state.seeds_by_sid, request.seed_sid)
    key = {seed.sid, request.sequence}
    floor = Map.get(state.evicted_through, seed.sid, 0)

    if request.sequence <= floor or :ets.member(state.table, key) do
      {:reply, {:ok, %{}}, state}
    else
      # A small sub-binary must not pin a larger incoming wire frame in ETS.
      output =
        if :binary.referenced_byte_size(request.output) > byte_size(request.output) do
          :binary.copy(request.output)
        else
          request.output
        end

      chunk = %DeploymentLog{
        owner: self(),
        org_id: state.deployment.org_id,
        deployment_id: state.deployment.id,
        deployment_sid: state.deployment.sid,
        seed_sid: seed.sid,
        sequence: request.sequence,
        output: output
      }

      :ets.insert(state.table, {key, chunk})

      state = %{
        state
        | bytes: state.bytes + byte_size(request.output),
          count: state.count + 1,
          order: :queue.in(key, state.order)
      }

      {state, evicted} = evict(state, [])

      DeploymentPubSub.broadcast_seed_deployment_log(%{
        chunk
        | reset?: state.reset?,
          evicted: evicted
      })

      {:reply, {:ok, %{}}, %{state | reset?: false}}
    end
  end

  defp evict(%State{} = state, evicted)
       when state.bytes <= state.max_bytes and state.count <= state.max_chunks do
    {state, Enum.reverse(evicted)}
  end

  defp evict(%State{} = state, evicted) do
    {{:value, {seed_sid, sequence} = key}, order} = :queue.out(state.order)
    [{^key, chunk}] = :ets.take(state.table, key)
    floor = max(sequence, Map.get(state.evicted_through, seed_sid, 0))

    state = %{
      state
      | bytes: state.bytes - byte_size(chunk.output),
        count: state.count - 1,
        order: order,
        evicted_through: Map.put(state.evicted_through, seed_sid, floor)
    }

    evict(state, [key | evicted])
  end
end
