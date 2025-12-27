defmodule Mix.Tasks.Cli.Run do
  @moduledoc "Run the Sower CLI"
  @shortdoc "Run the Sower CLI"

  use Mix.Task

  def run(args) do
    {:ok, _} = Application.ensure_all_started(:erlexec)

    SowerCli.main(args)
  end
end
