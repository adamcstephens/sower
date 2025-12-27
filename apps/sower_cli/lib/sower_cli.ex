defmodule SowerCli do
  @moduledoc """
  Sower CLI - Build and deploy Nix flakes.
  """

  def main(argv) do
    config()
    |> Optimus.parse!(argv)
    |> run()
  end

  defp run({[:build], %{args: args, flags: flags, options: options}}) do
    SowerCli.Build.run(args.flake, flags, options)
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

  def config do
    Optimus.new!(
      name: "sower",
      description: "Build and deploy Nix flakes",
      version: version(),
      subcommands: [
        build: [
          name: "build",
          about: "Build derivations from a Nix flake",
          args: [
            flake: [
              value_name: "FLAKE",
              help: "Flake reference (e.g., '.', '.#attr', 'github:owner/repo')",
              required: true
            ]
          ],
          flags: [
            eval_only: [
              short: "-e",
              long: "--eval-only",
              help: "Only evaluate, don't build"
            ],
            push: [
              short: "-p",
              long: "--push",
              help: "Push built paths to cache"
            ],
            seed: [
              short: "-s",
              long: "--seed",
              help: "Full pipeline: build, push, and register with server"
            ],
            fail_fast: [
              short: "-f",
              long: "--fail-fast",
              help: "Exit immediately if any step fails (default: continue with successful items)"
            ]
          ],
          options: [
            cache: [
              short: "-c",
              long: "--cache",
              value_name: "URL",
              help: "Cache destination (e.g., 'attic://server:cache', 'ssh://host')",
              required: false
            ],
            jobs: [
              short: "-j",
              long: "--jobs",
              value_name: "N",
              help: "Number of parallel workers",
              parser: :integer,
              default: 4
            ],
            tag: [
              short: "-t",
              long: "--tag",
              value_name: "KEY=VALUE",
              help: "Add metadata tag (can be repeated)",
              multiple: true
            ],
            type: [
              long: "--type",
              value_name: "TYPE",
              help: "Evaluation type: auto, flake, or path (default: auto)",
              parser: &parse_nix_type/1,
              default: :auto
            ]
          ]
        ]
      ]
    )
  end

  defp version do
    Path.expand("../../../VERSION", __DIR__)
    |> File.read!()
    |> String.trim()
  end

  defp parse_nix_type("auto"), do: {:ok, :auto}
  defp parse_nix_type("flake"), do: {:ok, :flake}
  defp parse_nix_type("path"), do: {:ok, :path}

  defp parse_nix_type(other) do
    {:error, "invalid type '#{other}', expected: auto, flake, or path"}
  end
end
