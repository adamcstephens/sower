defmodule SowerCli do
  def main(argv) do
    config()
    |> Optimus.parse!(argv)
    |> run()
  end

  defp run({subcommand_path, _}) when is_list(subcommand_path) do
    config()
    |> Optimus.Help.help(subcommand_path, columns())
    |> Enum.map(&IO.puts/1)
  end

  defp run(_) do
    config()
    |> Optimus.help()
    |> IO.puts()
  end

  defp columns() do
    case Optimus.Term.width() do
      {:ok, width} -> width
      _ -> 80
    end
  end

  def config() do
    Optimus.new!(
      name: "sower",
      description: "sower",
      version: Keyword.get(Mix.Project.config(), :version, "dev"),
      subcommands: [
        build: [
          name: "build"
        ],
        seed: [
          name: "seed",
          subcommands: [
            submit: [
              name: "submit"
            ]
          ]
        ]
      ]
    )
  end
end
