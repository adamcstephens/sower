defmodule Nix.Build.Jobs do
  @moduledoc """
  Runs multiple Nix builds concurrently using a Task.Supervisor.
  """
  use GenServer
  use TypedStruct

  alias Nix.Build

  require Logger

  @default_timeout_ms 60 * 60 * 1000
  @default_max_workers 4

  typedstruct do
    field :evals, list(Nix.Eval.t())
    field :max_workers, integer(), default: @default_max_workers
    field :supervisor, pid()
    field :from, {pid(), term()}
  end

  typedstruct module: Result do
    field :results, list(Nix.Build.t()), default: []
    field :start_time, DateTime.t()
    field :end_time, DateTime.t()
    field :status, :ok | :error
  end

  @doc """
  Run builds for a list of Nix.Eval structs concurrently.

  Returns `{%Result{}, list(Nix.Build.t())}` where Result contains timing
  and overall status.

  ## Options
  - `:max_workers` - Maximum concurrent builds (default: #{@default_max_workers})
  - `:timeout` - Overall job timeout in milliseconds (default: 1 hour)

  ## Examples

      evals = [eval1, eval2, eval3]
      {result, builds} = Nix.Build.Jobs.run(evals, max_workers: 2)
      result.status  # => :ok or :error
  """
  @spec run(list(Nix.Eval.t()), keyword()) :: {Result.t(), list(Build.t())}
  def run(evals, opts \\ []) when is_list(evals) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    {:ok, pid} = GenServer.start(__MODULE__, {evals, opts})
    GenServer.call(pid, :run, timeout)
  end

  @impl true
  def init({evals, opts}) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    state = %__MODULE__{
      evals: evals,
      max_workers: Keyword.get(opts, :max_workers, @default_max_workers),
      supervisor: supervisor
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:run, from, state) do
    start_time = DateTime.utc_now()

    Logger.info(
      msg: "Starting build jobs",
      count: length(state.evals),
      max_workers: state.max_workers
    )

    builds =
      Task.Supervisor.async_stream_nolink(
        state.supervisor,
        state.evals,
        fn eval -> run_build(eval) end,
        max_concurrency: state.max_workers,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, build} ->
          build

        {:exit, reason} ->
          Logger.warning(msg: "Build task crashed", reason: reason)
          build_from_crash(reason)
      end)

    end_time = DateTime.utc_now()
    status = compute_status(builds)

    Logger.info(
      msg: "Build jobs complete",
      count: length(builds),
      status: status,
      duration_ms: DateTime.diff(end_time, start_time, :millisecond)
    )

    result = %Result{
      start_time: start_time,
      end_time: end_time,
      status: status,
      results: builds
    }

    # Reply before stopping to ensure the caller receives the response
    GenServer.reply(from, {status, result})
    {:stop, :normal, %{state | from: from}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.supervisor do
      # Use try/catch in case the supervisor is already down
      try do
        if Process.alive?(state.supervisor) do
          Supervisor.stop(state.supervisor, :shutdown)
        end
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp run_build(eval) do
    {_status, build} = Build.run(eval)
    build
  end

  defp compute_status(builds) do
    if Enum.all?(builds, &(&1.status == :ok)) do
      :ok
    else
      :error
    end
  end

  defp build_from_crash(reason) do
    %Build{
      status: :error,
      log: [format_crash_reason(reason)],
      start_time: DateTime.utc_now(),
      end_time: DateTime.utc_now()
    }
  end

  defp format_crash_reason(:normal), do: "Task exited normally without result"
  defp format_crash_reason(reason), do: Exception.format_exit(reason)
end
