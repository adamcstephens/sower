defmodule Garden.VM.CLI do
  @moduledoc """
  Local entrypoint: `mix sower.vm.run IMAGE --request JSON`.

  Request JSON contains path, args, env and stdin. Alternatively supply
  `--path`, `--argv` (JSON array), `--env` (JSON object), and `--payload` (JSON).
  Resource options are `--cpus`, `--memory-mib`, `--scratch-mib`, and
  `--deadline-ms`. Output streams remain raw; status is returned to the caller.
  Starts the standalone VM manager without starting Garden.
  """
  alias Garden.Image
  alias VMManager.Command
  require Logger

  def main(argv) do
    {options, positional, invalid} =
      OptionParser.parse(argv,
        strict: [
          request: :string,
          path: :string,
          argv: :string,
          env: :string,
          payload: :string,
          cpus: :integer,
          memory_mib: :integer,
          scratch_mib: :integer,
          deadline_ms: :integer
        ]
      )

    with [] <- invalid,
         [directory] <- positional,
         {:ok, command} <- command(options),
         {:ok, image} <- Image.load(directory),
         {:ok, _apps} <- Application.ensure_all_started(:vm_manager) do
      run(image, command,
        cpus: Keyword.get(options, :cpus, 1),
        memory: Keyword.get(options, :memory_mib, 512) * 1024 * 1024,
        scratch_bytes: Keyword.get(options, :scratch_mib, 4096) * 1024 * 1024,
        deadline_ms: Keyword.get(options, :deadline_ms, 60_000)
      )
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :usage}
    end
  end

  def run(%Image{} = image, %Command{} = command, options \\ []) do
    {manager, options} = Keyword.pop(options, :manager, VMManager.Manager)
    id = "cli-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    config = Image.vm_config(image, id, Keyword.drop(options, [:deadline_ms, :on_output]))

    caller = self()
    reference = make_ref()

    {owner, monitor} =
      spawn_monitor(fn ->
        own_disposable(caller, reference, config, command, options, manager)
      end)

    receive do
      {^reference, {:return, result}} ->
        Process.demonitor(monitor, [:flush])
        result

      {^reference, {:exit, reason}} ->
        Process.demonitor(monitor, [:flush])
        exit(reason)

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        exit(reason)
    end
  end

  defp own_disposable(
         caller,
         reference,
         %VMManager.Config{} = config,
         %Command{} = command,
         options,
         manager
       ) do
    caller_monitor = Process.monitor(caller)

    case VMManager.define(config, manager) do
      {:ok, id} ->
        owner = self()

        {worker, worker_monitor} =
          spawn_monitor(fn ->
            result = run_command(id, command, options, manager)
            send(owner, {:command_result, self(), result})
          end)

        receive do
          {:command_result, ^worker, result} ->
            finish_disposable(caller, reference, id, manager, {:return, result})

          {:DOWN, ^worker_monitor, :process, ^worker, reason} ->
            finish_disposable(caller, reference, id, manager, {:exit, reason})

          {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
            Process.exit(worker, :kill)

            receive do
              {:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok
            end

            cleanup_disposable(id, manager)
        end

      {:error, reason} ->
        send(caller, {reference, {:return, {:error, reason}}})
    end
  end

  defp run_command(id, %Command{} = command, options, manager) do
    with :ok <- VMManager.start(id, manager),
         {:ok, _status} <- VMManager.await_ready(id, manager),
         {:ok, handle} <-
           VMManager.execute(
             id,
             command,
             Keyword.take(options, [:deadline_ms, :on_output]),
             manager
           ) do
      VMManager.await_command(handle)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_disposable(caller, reference, id, manager, outcome) do
    case cleanup_disposable(id, manager) do
      :ok -> send(caller, {reference, outcome})
      {:error, reason} -> send(caller, {reference, {:return, {:error, reason}}})
    end
  end

  defp cleanup_disposable(id, manager) do
    with :ok <- VMManager.stop(id, manager),
         :ok <- VMManager.remove(id, manager) do
      :ok
    else
      {:error, reason} ->
        Logger.error(msg: "Disposable VM cleanup incomplete", vm_id: id, reason: inspect(reason))
        {:error, reason}
    end
  end

  defp command(options) do
    if options[:request] do
      with {:ok, %{"path" => path} = request} <- Jason.decode(options[:request]) do
        {:ok,
         %Command{
           path: path,
           args: Map.get(request, "args", []),
           env: Map.get(request, "env", %{}),
           stdin: Map.get(request, "stdin", %{})
         }}
      else
        {:error, reason} -> {:error, reason}
        _ -> {:error, :invalid_request}
      end
    else
      with {:ok, args} <- Jason.decode(Keyword.get(options, :argv, "[]")),
           {:ok, env} <- Jason.decode(Keyword.get(options, :env, "{}")),
           {:ok, stdin} <- Jason.decode(Keyword.get(options, :payload, "{}")) do
        {:ok, %Command{path: options[:path], args: args, env: env, stdin: stdin}}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
