defmodule Mix.Tasks.Sower.Vm.Run do
  use Mix.Task

  @shortdoc "Run a command in a local Cloud Hypervisor VM"
  @requirements ["compile"]

  @impl Mix.Task
  def run(arguments) do
    case Garden.VM.CLI.main(arguments) do
      {:ok, %Garden.VM.Result{code: 0}} ->
        :ok

      {:ok, %Garden.VM.Result{code: code, signal: nil}} ->
        System.halt(code)

      {:ok, %Garden.VM.Result{code: nil, signal: signal}} ->
        System.halt(128 + signal)

      {:error, reason} ->
        Mix.raise("VM execution failed: #{inspect(reason)}")
    end
  end
end
