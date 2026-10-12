defmodule Garden.VM.CLI do
  @moduledoc """
  Local entrypoint: `mix sower.vm.run IMAGE --request JSON`.

  Request JSON contains path, args, env and stdin. Alternatively supply
  `--path`, `--argv` (JSON array), `--env` (JSON object), and `--payload` (JSON).
  Resource options are `--cpus`, `--memory-mib`, `--scratch-mib`, and
  `--deadline-ms`. Output streams remain raw; status is returned to the caller.
  Only Cloud Hypervisor's actual application dependencies are started.
  """
  alias Garden.{Image, VM}

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
         {:ok, _apps} <- Application.ensure_all_started(:cloud_hypervisor) do
      VM.run(image, command,
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

  defp command(options) do
    if options[:request] do
      with {:ok, %{"path" => path} = request} <- Jason.decode(options[:request]) do
        {:ok,
         %VM.Command{
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
        {:ok, %VM.Command{path: options[:path], args: args, env: env, stdin: stdin}}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
