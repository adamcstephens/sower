defmodule Nix.Eval.Jobs do
  use GenServer
  use TypedStruct

  typedstruct do
    field :queue, :queue.queue()
    field :running, %{reference() => String.t()}
    field :results, list()
    field :max_workers, integer()
    field :memory_limit_kb, integer()
    field :from, {pid(), term()}
  end

  def run(target, opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {target, opts})

    GenServer.call(pid, :run, 10 * 60 * 60 * 1000)
  end

  def init({target, opts}) do
    state = %__MODULE__{
      queue: :queue.from_list([target]),
      running: %{},
      results: [],
      max_workers: Keyword.get(opts, :workers, 8),
      memory_limit_kb: Keyword.get(opts, :memory_limit_kb, 4_000_000),
      from: nil
    }

    {:ok, state}
  end

  def handle_call(:run, from, state) do
    # Start spawning workers and don't reply yet
    state = %{state | from: from}
    state = spawn_workers(state)

    {:noreply, state}
  end

  # Spawn workers up to the limit while there's work in the queue
  defp spawn_workers(state) do
    available_slots = state.max_workers - map_size(state.running)
    queue_size = :queue.len(state.queue)
    to_spawn = min(available_slots, queue_size)

    if to_spawn > 0 do
      Enum.reduce(1..to_spawn, state, fn _, acc_state ->
        case :queue.out(acc_state.queue) do
          {{:value, target}, new_queue} ->
            task = Task.async(fn -> evaluate_target(target, acc_state.memory_limit_kb) end)

            %{acc_state | queue: new_queue, running: Map.put(acc_state.running, task.ref, target)}

          {:empty, _} ->
            acc_state
        end
      end)
    else
      state
    end
  end

  # Evaluate a single target and return the result
  defp evaluate_target(target, memory_limit_kb) when is_binary(target) do
    case Nix.Eval.run(target, memory_limit_kb: memory_limit_kb) do
      {_, %{output: output} = eval} when is_map(output) or is_nil(output) ->
        # This is a derivation (returns map with drvPath, outPath, meta)
        {:leaf, eval}

      {:ok, %{output: output}} when is_list(output) ->
        # Found more targets to evaluate (attrset with attribute names)
        new_targets = Enum.map(output, &"#{target}.#{&1}")
        {:branch, new_targets}
    end
  end

  # Handle task completion
  def handle_info({ref, result}, state) when is_reference(ref) do
    {_target, running} = Map.pop(state.running, ref)

    state =
      case result do
        {:leaf, eval} ->
          # This was a leaf node, add to results
          %{state | results: [eval | state.results]}

        {:branch, new_targets} ->
          # This was a branch, add new targets to queue
          new_queue =
            Enum.reduce(new_targets, state.queue, fn target, q ->
              :queue.in(target, q)
            end)

          %{state | queue: new_queue}
      end

    state = %{state | running: running}

    state =
      if :queue.is_empty(state.queue) and map_size(state.running) == 0 do
        results = Enum.reverse(state.results)
        GenServer.reply(state.from, {check_ok(results), results})
        state
      else
        spawn_workers(state)
      end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # Task processes exit normally after sending their result,
    # so we just acknowledge the DOWN message
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  defp check_ok(results) do
    if Enum.any?(results, fn eval -> eval.status == :error end) do
      :error
    else
      :ok
    end
  end
end
