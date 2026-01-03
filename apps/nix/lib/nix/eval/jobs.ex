defmodule Nix.Eval.Jobs do
  use GenServer
  use TypedStruct

  require Logger

  @tick_interval 5_000

  typedstruct do
    field :request, Nix.Eval.Request.t()
    field :queue, :ets.tid()
    field :queue_counter, reference()
    field :running, %{reference() => Nix.Eval.Request.t()}
    field :results, list()
    field :max_workers, integer()
    field :memory_limit_kb, integer()
    field :use_eval_cache, boolean(), default: false
    field :notify_pid, pid()
    field :from, {pid(), term()}
    field :supervisor, pid()
    field :start_time, DateTime.t()
  end

  typedstruct module: Result do
    field :request, Nix.Eval.Request.t()
    field :start_time, DateTime.t()
    field :end_time, DateTime.t()
    field :results, list()
  end

  def run(target, opts \\ [])

  def run(target, opts) when is_binary(target) do
    request_opts = Keyword.take(opts, [:attr, :type])
    run(Nix.Eval.Request.parse(target, request_opts), opts)
  end

  def run(%Nix.Eval.Request{} = request, opts) do
    {:ok, pid} = GenServer.start(__MODULE__, {request, opts})

    GenServer.call(pid, :run, 10 * 60 * 60 * 1000)
  end

  def init({request, opts}) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    {queue, counter} = Nix.Eval.Queue.new()
    Nix.Eval.Queue.enqueue(queue, counter, request)

    state = %__MODULE__{
      queue: queue,
      queue_counter: counter,
      running: %{},
      results: [],
      max_workers: Keyword.get(opts, :workers, 8),
      memory_limit_kb: Keyword.get(opts, :memory_limit_kb, 4_000_000),
      use_eval_cache: Keyword.get(opts, :use_eval_cache, false),
      notify_pid: Keyword.get(opts, :notify_pid),
      from: nil,
      request: request,
      supervisor: supervisor,
      start_time: DateTime.utc_now()
    }

    state = spawn_workers(state)
    Process.send_after(self(), :tick, 100)

    {:ok, state}
  end

  def handle_call(:run, from, state) do
    start_time = DateTime.utc_now()

    state =
      %{state | from: from, start_time: start_time}
      |> spawn_workers()

    {:noreply, state}
  end

  def handle_call({:set_max_workers, new_max}, _from, state) do
    {:reply, :ok, %{state | max_workers: new_max}}
  end

  # Spawn workers up to the limit while there's work in the queue
  defp spawn_workers(state) do
    available_slots = state.max_workers - map_size(state.running)
    queue_size = Nix.Eval.Queue.size(state.queue)
    to_spawn = min(available_slots, queue_size)

    if to_spawn > 0 do
      if to_spawn > 1 do
        Logger.debug(
          msg: "Spawning workers",
          count: to_spawn,
          available_slots: available_slots,
          queue_size: queue_size,
          running: map_size(state.running),
          max_workers: state.max_workers
        )
      end

      # Dequeue all needed requests at once
      requests = Nix.Eval.Queue.dequeue(state.queue, to_spawn)

      # Spawn workers for dequeued requests
      running =
        Enum.reduce(requests, state.running, fn request, acc_running ->
          notify(state, {:eval_started, request.attr})

          task =
            Task.Supervisor.async(state.supervisor, fn ->
              evaluate_request(request, state)
            end)

          Map.put(acc_running, task.ref, request)
        end)

      %{state | running: running}
    else
      state
    end
  end

  # Evaluate a single request and return the result
  defp evaluate_request(request, %__MODULE__{memory_limit_kb: mem, use_eval_cache: cache}) do
    case Nix.Eval.run(request, memory_limit_kb: mem, use_eval_cache: cache) do
      {_, %{output: output} = eval} when is_map(output) or is_nil(output) ->
        # This is a derivation (returns map with drvPath, outPath, meta)
        {:leaf, eval}

      {:ok, %{output: output}} when is_list(output) ->
        {:branch, output}

      other ->
        # Unexpected return value - treat as error leaf
        {:leaf,
         %Nix.Eval{
           request: request,
           status: :error,
           output: nil,
           errors: ["Unexpected return value: #{inspect(other)}"]
         }}
    end
  end

  @doc """
  Result of the evaluation
  """
  def handle_info({ref, result}, state) when is_reference(ref) do
    state = process_task_result(ref, result, state)

    # Drain additional messages from mailbox to reduce processing overhead
    state = drain_mailbox(state, 50)

    if Nix.Eval.Queue.empty?(state.queue) and map_size(state.running) == 0 do
      Logger.info(msg: "All work complete", total_results: length(state.results))
      results = Enum.reverse(state.results)

      GenServer.reply(
        state.from,
        {check_ok(results),
         %Nix.Eval.Jobs.Result{
           results: results,
           end_time: DateTime.utc_now(),
           start_time: state.start_time,
           request: state.request
         }}
      )

      {:stop, :normal, state}
    else
      {:noreply, spawn_workers(state)}
    end
  end

  # Just ignore the down events, we get everything we need from the result
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    Logger.info(
      msg: "Flush requested",
      running: map_size(state.running),
      queue: Nix.Eval.Queue.size(state.queue),
      max_workers: state.max_workers
    )

    {:noreply, spawn_workers(state)}
  end

  def handle_info(:tick, state) do
    available_slots = state.max_workers - map_size(state.running)
    queue_size = Nix.Eval.Queue.size(state.queue)

    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, len} ->
        Logger.info(
          msg: "Messages in queue",
          max_workers: state.max_workers,
          queue_size: queue_size,
          available_slots: available_slots,
          message_queue_len: len,
          processed: length(state.results)
        )
    end

    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning(msg: "Unexpected message in Jobs GenServer", message: msg)
    {:noreply, state}
  end

  # Process a single task result and update state
  defp process_task_result(ref, result, state) do
    case Map.pop(state.running, ref) do
      {nil, _running} ->
        # Task already handled (likely by :DOWN handler in race condition)
        Logger.warning(msg: "Received result for unknown task", ref: ref)
        state

      {request, running} ->
        state =
          case result do
            {:leaf, %Nix.Eval{status: status} = eval_result} ->
              notify(state, {:eval_completed, request.attr, status})
              %{state | results: [eval_result | state.results]}

            {:branch, new_targets} ->
              # Bulk enqueue - now fast with ETS!
              notify(state, {:eval_completed, request.attr, :branch})
              Nix.Eval.Queue.enqueue(state.queue, state.queue_counter, new_targets)
              state

            unexpected ->
              Logger.error(
                msg: "Unexpected task result format",
                result: unexpected,
                request: request
              )

              notify(state, {:eval_completed, request.attr, :error})

              error_eval = %Nix.Eval{
                request: request,
                status: :error,
                output: nil,
                errors: ["Unexpected task result format: #{inspect(unexpected)}"]
              }

              %{state | results: [error_eval | state.results]}
          end

        %{state | running: running}
    end
  end

  # Drain up to N messages from mailbox without blocking
  defp drain_mailbox(state, 0), do: state

  defp drain_mailbox(state, n) do
    receive do
      {ref, result} when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        state = process_task_result(ref, result, state)
        drain_mailbox(state, n - 1)

      {:DOWN, ref, :process, _pid, :normal} ->
        # Fast path: just remove from running if present
        state =
          case Map.pop(state.running, ref) do
            {nil, _} -> state
            {_request, running} -> %{state | running: running}
          end

        drain_mailbox(state, n - 1)

      {:DOWN, ref, :process, _pid, reason} ->
        # Handle crash
        state = handle_task_crash(ref, reason, state)
        drain_mailbox(state, n - 1)
    after
      0 -> state
    end
  end

  # Handle a task crash and create error result
  defp handle_task_crash(ref, reason, state) do
    case Map.pop(state.running, ref) do
      {nil, _} ->
        state

      {request, running} ->
        Logger.warning(
          msg: "Task crashed without result",
          request: request,
          reason: reason,
          running_count: map_size(running),
          queue_size: Nix.Eval.Queue.size(state.queue)
        )

        error_eval = %Nix.Eval{
          request: request,
          status: :error,
          output: nil,
          errors: [format_crash_reason(reason)]
        }

        %{state | running: running, results: [error_eval | state.results]}
    end
  end

  defp check_ok(results) do
    if Enum.all?(results, fn eval -> eval.status == :ok end) do
      :ok
    else
      :error
    end
  end

  def terminate(_reason, state) do
    # Stop the task supervisor to clean up any remaining tasks
    if state.supervisor && Process.alive?(state.supervisor) do
      Supervisor.stop(state.supervisor, :shutdown)
    end

    # Clean up ETS queue
    Nix.Eval.Queue.delete(state.queue)

    :ok
  end

  defp format_crash_reason(:normal), do: "Task exited normally without result"
  defp format_crash_reason(reason), do: Exception.format_exit(reason)

  defp notify(%__MODULE__{notify_pid: nil}, _event), do: :ok
  defp notify(%__MODULE__{notify_pid: pid}, event), do: send(pid, event)
end
