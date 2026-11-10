defmodule Mix.Tasks.Sower.Vm.Run do
  @moduledoc """
  Runs a command in a disposable local VM using `Garden.VM.CLI`.

  The guest exit code becomes the task's exit status; a signal maps to 128 plus
  its number. VM execution failures are raised as Mix errors.
  """

  use Mix.Task

  @shortdoc "Run a command in a local Cloud Hypervisor VM"
  @requirements ["compile"]

  @impl Mix.Task
  def run(arguments) do
    case Garden.VM.CLI.main(arguments) do
      {:ok, %VMManager.Result{code: 0}} ->
        :ok

      {:ok, %VMManager.Result{code: code, signal: nil}} ->
        System.halt(code)

      {:ok, %VMManager.Result{code: nil, signal: signal}} ->
        System.halt(128 + signal)

      {:error, reason} ->
        Mix.raise("VM execution failed: #{inspect(reason)}")
    end
  end
end
