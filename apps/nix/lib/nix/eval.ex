defmodule Nix.Eval do
  use GenServer
  use TypedStruct

  alias Nix.Eval

  require Logger

  @default_timeout_ms 60 * 60 * 1000
  @default_memory_limit_kb 4_000_000
  @tick_interval 200

  typedstruct do
    field :request, Eval.Request.t()
    field :start_time, DateTime.t()
    field :end_time, DateTime.t()
    field :mem_samples, list(integer()), default: []
    field :output, list(binary()) | map() | nil, default: []
    field :errors, list(binary()) | binary(), default: []
    field :memory_limit_kb, integer()
    field :status, :ok | :error | :memory_limit_exceeded
  end

  typedstruct module: Exec do
    field :eval, Nix.Eval.t()
    field :from, pid()
    field :pid, pid()
    field :ospid, integer()
    field :use_eval_cache, boolean()
  end

  def run(target, opts \\ [])

  def run(target, opts) when is_binary(target) do
    run(Eval.Request.parse(target, Keyword.get(opts, :attr)), opts)
  end

  def run(%Eval.Request{} = request, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    {:ok, pid} = GenServer.start_link(Eval, {request, opts})

    try do
      # if this timeout is exceeded the child process may not be killed
      GenServer.call(pid, :run, timeout)
    catch
      :exit, {:timeout, {GenServer, :call, _}} ->
        Logger.error(msg: "Timed out running eval", path: request.path, attr: request.attr)
        {:error, build_error_result(request, :timeout)}
    end
  end

  def run!(target, opts \\ []) do
    {:ok, eval} = run(target, opts)
    eval
  end

  def init({%Eval.Request{} = req, opts}) do
    Process.flag(:trap_exit, true)

    state =
      %Eval.Exec{
        use_eval_cache: Keyword.get(opts, :use_eval_cache, false),
        eval: %Eval{
          request: req,
          memory_limit_kb: Keyword.get(opts, :memory_limit_kb, @default_memory_limit_kb)
        }
      }

    {:ok, state}
  end

  def handle_call(:run, from, %Eval.Exec{} = state) do
    start_time = DateTime.utc_now()

    # we can't name the attribute outPath, or nix will only return that in the json
    expr_body = """
    if (!(builtins.isAttrs x)) then
      null
    else
      if (x.type or null == "derivation") then
        { drvPath = x.drvPath; storePath = x.outPath; meta = x.meta or {}; system = x.system; }
      else
        builtins.attrNames x
    """

    cmd =
      case state.eval.request.type do
        :flake ->
          [
            System.find_executable("nix"),
            "eval"
          ] ++
            if(state.use_eval_cache, do: [], else: ["--no-eval-cache"]) ++
            [
              "--json",
              Eval.Request.to_flake_uri(state.eval.request),
              "--apply",
              """
              x: #{expr_body}
              """
            ]

        :path ->
          [
            System.find_executable("nix-instantiate"),
            "--eval",
            "--strict",
            "--json"
          ] ++
            if(state.use_eval_cache, do: [], else: ["--option", "eval-cache", "false"]) ++
            [
              "--expr",
              """
              let
                x = #{Eval.Request.to_import(state.eval.request)};
              in
              #{expr_body}
              """
            ]
      end

    Logger.debug(msg: "Running command", cmd: Enum.join(cmd, " "))

    {:ok, pid, ospid} =
      :exec.run_link(
        cmd,
        [
          :stdout,
          :stderr
        ]
      )

    state = %{
      state
      | pid: pid,
        ospid: ospid,
        from: from,
        eval: %{state.eval | start_time: start_time}
    }

    Process.send_after(self(), :tick, @tick_interval)
    {:noreply, state}
  end

  def handle_info({:stdout, ospid, stdout}, %Eval.Exec{} = state) when ospid == state.ospid do
    {:noreply, %{state | eval: %{state.eval | output: [stdout | state.eval.output]}}}
  end

  def handle_info({:stderr, ospid, stderr}, %Eval.Exec{} = state) when ospid == state.ospid do
    {:noreply, %{state | eval: %{state.eval | errors: [stderr | state.eval.errors]}}}
  end

  def handle_info(:tick, %Eval.Exec{} = state) do
    mem = get_mem(state.ospid)

    if not is_nil(mem) do
      cond do
        mem > state.eval.memory_limit_kb ->
          Logger.warning(
            msg: "Memory has exceeded limit, killing",
            eval_id: state.eval.request.id,
            ospid: state.ospid,
            memory_limit_kb: state.eval.memory_limit_kb,
            active_memory_kb: mem
          )

          :exec.kill(state.pid, :sigterm)

        true ->
          :ok
      end
    end

    Process.send_after(self(), :tick, @tick_interval)

    mem_samples =
      if is_nil(mem) do
        state.eval.mem_samples
      else
        [mem | state.eval.mem_samples]
      end

    {:noreply, %{state | eval: %{state.eval | mem_samples: mem_samples}}}
  end

  def handle_info({:EXIT, pid, reason}, %Eval.Exec{} = state) when pid == state.pid do
    end_time = DateTime.utc_now()

    status =
      cond do
        reason == :normal ->
          :ok

        length(state.eval.mem_samples) > 0 and
            Enum.max(state.eval.mem_samples) >= state.eval.memory_limit_kb ->
          :memory_limit_exceeded

        true ->
          :error
      end

    state = %{
      state
      | eval: %{
          state.eval
          | output: finalize_output(state.eval),
            errors: finalize_errors(state.eval.errors),
            end_time: end_time,
            status: status
        }
    }

    log = [
      msg: "Evaluation complete",
      request: state.eval.request,
      reason: reason,
      status: status,
      errors: state.eval.errors
    ]

    if status == :ok do
      Logger.debug(log)
    else
      Logger.warning(log)
    end

    GenServer.reply(state.from, {status, state.eval})

    {:stop, :normal, state}
  end

  def finalize_output(%Eval{request: %Eval.Request{} = req, output: output}) do
    case output |> Enum.reverse() |> Enum.join() |> Jason.decode() do
      {:ok, json} when is_list(json) ->
        Enum.map(json, fn child ->
          attr =
            if is_nil(req.attr) do
              child
            else
              "#{req.attr}.#{child}"
            end

          %{req | attr: attr, id: Eval.Request.new_id(), root_id: req.root_id || req.id}
        end)

      {:ok, json} ->
        json

      {:error, _} ->
        if output == [], do: nil, else: output
    end
  end

  def finalize_errors(errors) when is_list(errors) do
    errors
    |> Enum.reverse()
    |> Enum.map(&String.split(&1, "\n"))
    |> List.flatten()
    |> Enum.reject(fn l ->
      Regex.match?(~r{(fetching git input|error \(ignored\): error: SQLite database|^$)}, l)
    end)
  end

  def build_error_result(request, reason) do
    %Nix.Eval{
      request: request,
      status: :error,
      output: nil,
      errors: [format_error(reason)],
      start_time: DateTime.utc_now(),
      end_time: DateTime.utc_now()
    }
  end

  defp format_error(:normal), do: "Task exited normally without result"
  defp format_error(reason), do: Exception.format_exit(reason)

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
        Logger.debug(msg: "proc file does not exist")
        nil

      {:error, reason} ->
        Logger.debug(msg: "failed to read proc file", reason: reason)
        nil
    end
  end
end
