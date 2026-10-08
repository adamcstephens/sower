defmodule Mix.Tasks.Sower.Image.Run do
  use Mix.Task

  @shortdoc "Run an image-contained command in a local Cloud Hypervisor VM"
  @requirements ["compile"]

  @impl Mix.Task
  def run(arguments) do
    case Garden.Image.CLI.main(arguments) do
      {:ok, %Garden.Image.Result{code: 0}} ->
        :ok

      {:ok, %Garden.Image.Result{code: code, signal: nil}} ->
        System.halt(code)

      {:ok, %Garden.Image.Result{code: nil, signal: signal}} ->
        System.halt(128 + signal)

      {:error, reason} ->
        Mix.raise("Image execution failed: #{inspect(reason)}")
    end
  end
end
