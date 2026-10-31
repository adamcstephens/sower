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
    id = "cli-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    config = Image.vm_config(image, id, Keyword.drop(options, [:deadline_ms, :on_output]))

    with {:ok, ^id} <- VMManager.define(config) do
      result =
        with :ok <- VMManager.start(id),
             {:ok, _status} <- VMManager.await_ready(id),
             {:ok, handle} <-
               VMManager.execute(id, command, Keyword.take(options, [:deadline_ms, :on_output])) do
          VMManager.await_command(handle)
        else
          {:error, reason} -> {:error, reason}
        end

      case VMManager.stop(id) do
        :ok ->
          case VMManager.remove(id) do
            :ok -> result
            {:error, reason} -> {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
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
