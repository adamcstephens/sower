defmodule Mix.Tasks.Cli.Run do
  use Mix.Task

  def run(args) do
    # Application.ensure_all_started(:sower_cli)

    SowerCli.main(args)
  end
end
