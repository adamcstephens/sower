defmodule Mix.Tasks.Cli.Run do
  @moduledoc "Run the Sower CLI"
  @shortdoc "Run the Sower CLI"

  use Mix.Task

  def run(args) do
    SowerCli.main(args)
  end
end
