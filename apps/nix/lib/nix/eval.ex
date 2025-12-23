defmodule Nix.Eval do
  use GenServer
  use TypedStruct

  require Logger

  @default_memory_limit_kb 4_000_000
  @tick_interval 200

  typedstruct do
    field :target, binary()
    field :from, pid()
    field :pid, pid()
    field :ospid, integer()
    field :start_time, DateTime.t()
    field :end_time, DateTime.t()
    field :mem_samples, list(integer() | nil), default: []
    field :output, list(binary()) | map() | nil, default: []
    field :errors, list(binary()) | binary(), default: []
    field :memory_limit_kb, integer()
    field :extra_args, list(binary), default: []
    field :status, :ok | :error | :memory_limit_exceeded
  end

  def run(target, opts \\ []) do
    {:ok, pid} = GenServer.start_link(__MODULE__, {target, opts})

    # set a 10 hour timeout for the genserver
    # if this timeout is exceeded the child process may not be killed
    GenServer.call(pid, :run_process, 10 * 60 * 60 * 1000)
  end

  def init({target, opts}) do
    Process.flag(:trap_exit, true)

    state =
      %__MODULE__{
        target: target,
        memory_limit_kb: Keyword.get(opts, :memory_limit_kb, @default_memory_limit_kb),
        extra_args: Keyword.get(opts, :extra_args, [])
      }

    {:ok, state}
  end

  def handle_call(:run_process, from, %__MODULE__{} = state) do
    start_time = DateTime.utc_now()

    cmd = [
      System.find_executable("nix"),
      "eval",
      "--json",
      state.target,
      "--no-eval-cache",
      "--apply",
      # we can't name the attribute outPath, or nix will only return that in the json
      ~s|x: if (x?type && x.type == "derivation") then { drvPath = x.drvPath; storePath = x.outPath; meta = x.meta or {}; } else builtins.attrNames x|
    ]

    Logger.debug(msg: "Running command", cmd: Enum.join(cmd, " "))

    {:ok, pid, ospid} =
      :exec.run_link(
        cmd,
        [
          :stdout,
          :stderr
        ]
      )

    state = %{state | pid: pid, ospid: ospid, from: from, start_time: start_time}

    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  def handle_info({:stdout, ospid, stdout}, %__MODULE__{} = state) when ospid == state.ospid do
    {:noreply, %{state | output: [stdout | state.output]}}
  end

  def handle_info({:stderr, ospid, stderr}, %__MODULE__{} = state) when ospid == state.ospid do
    {:noreply, %{state | errors: [stderr | state.errors]}}
  end

  def handle_info(:tick, %__MODULE__{} = state) do
    mem = get_mem(state.ospid)

    if not is_nil(mem) do
      cond do
        mem > state.memory_limit_kb ->
          Logger.warning(
            msg: "Memory has exceeded limit, killing",
            ospid: state.ospid,
            memory_limit_kb: state.memory_limit_kb,
            active_memory_kb: mem
          )

          :exec.kill(state.pid, :sigterm)

        mem > state.memory_limit_kb * 0.75 ->
          Logger.debug(
            msg: "Memory above 1/2 of limit",
            ospid: state.ospid,
            memory_limit_kb: state.memory_limit_kb,
            active_memory_kb: mem
          )

        true ->
          :ok
      end
    end

    Process.send_after(self(), :tick, @tick_interval)

    {:noreply, %{state | mem_samples: [mem | state.mem_samples]}}
  end

  def handle_info({:EXIT, pid, reason}, %__MODULE__{} = state) when pid == state.pid do
    end_time = DateTime.utc_now()

    status =
      cond do
        reason == :normal -> :ok
        Enum.max(state.mem_samples) >= state.memory_limit_kb -> :memory_limit_exceeded
        true -> :error
      end

    state = %{
      state
      | output: finalize_output(state.output),
        errors: finalize_errors(state.errors),
        end_time: end_time,
        status: status
    }

    log = [
      msg: "Evaluation complete",
      target: state.target,
      reason: reason,
      status: status,
      errors: state.errors
    ]

    if status == :ok do
      Logger.info(log)
    else
      Logger.warning(log)
    end

    GenServer.reply(state.from, {status, state})

    {:stop, :normal, state}
  end

  def finalize_output(output) do
    case output |> Enum.reverse() |> Enum.join() |> Jason.decode() do
      {:ok, json} -> json
      {:error, _} -> if output == [], do: nil, else: output
    end
  end

  def finalize_errors(errors) do
    errors
    |> Enum.reverse()
    |> Enum.map(&String.split(&1, "\n"))
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn l ->
      Regex.match?(~r{(fetching git input|error \(ignored\): error: SQLite database|^$)}, l)
    end)
  end

  defp get_mem(ospid) do
    case File.read("/proc/#{ospid}/status") do
      {:ok, text} ->
        text
        |> String.split("\n")
        |> Enum.find(&String.starts_with?(&1, "VmRSS:"))
        |> case do
          "VmRSS:" <> rest ->
            rest |> String.split() |> hd() |> String.to_integer()

          _ ->
            Logger.debug(msg: "proc status file does not have VmRSS")
            nil
        end

      {:error, :enoent} ->
        Logger.warning(msg: "proc file does not exist")
        nil
    end
  end
end
