defmodule SowerCli do
  @moduledoc """
  Sower CLI - Build and deploy Nix flakes.
  """

  require Logger

  @version Path.expand("../../../VERSION", __DIR__) |> File.read!() |> String.trim()

  def main(argv) do
    # Load config at startup
    SowerCli.Config.load(config_path_env: "SOWER_CLI_CONFIG")

    Application.get_all_env(:sower_cli)

    {subcommands, parsed} =
      config()
      |> Optimus.parse!(argv)

    # Set log level after all apps have started
    set_log_level(if parsed.flags.debug, do: :debug, else: :error)

    result = run({subcommands, parsed})

    case result do
      {:error, _reason} -> System.halt(1)
      _ -> System.halt(0)
    end
  end

  defp run({[:build], %{args: args, flags: flags, options: options}}) do
    SowerCli.Build.run(args.target, flags, options)
  end

  defp run({[:repo, :show_tags], _}) do
    SowerCli.Repo.get_tags(".", :flake)
  end

  defp run({[:seed, :download], %{flags: flags, options: options}}) do
    SowerCli.Seed.Download.run(flags, options)
  end

  defp run({[:seed, :info], %{flags: flags, options: options}}) do
    SowerCli.Seed.Info.run(flags, options)
  end

  defp run({[:seed, :upgrade], %{flags: flags, options: options}}) do
    SowerCli.Seed.Upgrade.run(flags, options)
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

  defp set_log_level(level) do
    Logger.configure(level: level)
    :logger.set_primary_config(:level, level)

    for %{id: id} <- :logger.get_handler_config() do
      :logger.set_handler_config(id, :level, level)
    end
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
      version: version(),
      flags: [
        debug: [
          short: "-d",
          long: "--debug",
          help: "Enable debug logging",
          global: true
        ]
      ],
      subcommands: [
        build: [
          name: "build",
          about: "Build derivations from a Nix attribute or flake",
          args: [
            target: [
              value_name: "TARGET",
              help:
                "Path to Nix file or Flake reference (e.g., '.', '.#attr', 'github:owner/repo')",
              required: true
            ]
          ],
          flags: [
            non_authoritative: [
              long: "--non-authoritative",
              help:
                "By default cli builds are 'authoritative' and will rename seeds that match artifacts"
            ],
            eval_only: [
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
            use_eval_cache: [
              long: "--use-eval-cache",
              help:
                "Enable evaluation caching. This is disabled by default, unlike standard commands."
            ],
            fail_fast: [
              short: "-f",
              long: "--fail-fast",
              help: "Exit immediately if any step fails (default: continue with successful items)"
            ],
            attr: [
              short: "-A",
              long: "--attr",
              help: "Attribute to evaluate for non-flakes, default is all attributes"
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
            eval_jobs: [
              long: "--eval-jobs",
              value_name: "N",
              help: "Number of parallel eval workers",
              parser: :integer,
              default: 4
            ],
            build_jobs: [
              short: "-j",
              long: "--build-jobs",
              value_name: "N",
              help: "Number of parallel build workers",
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
            eval_type: [
              long: "--eval-type",
              value_name: "TYPE",
              help: "Evaluation type: auto, flake, or path (default: auto)",
              parser: &parse_nix_type/1,
              default: :auto
            ],
            memory_limit: [
              short: "-m",
              long: "--memory-limit",
              value_name: "MB",
              help: "Memory limit per evaluation in MB (default: 4000)",
              parser: :integer,
              default: 4_000
            ]
          ]
        ],
        repo: [
          name: "repo",
          about: "repo management and information",
          subcommands: [
            show_tags: [
              name: "show-tags",
              about: "Show repository detected tags",
              flags: [],
              options: []
            ]
          ]
        ],
        seed: [
          name: "seed",
          about: "Manage seeds",
          subcommands: [
            download: [
              name: "download",
              about: "Download and realize a seed from the server",
              flags: [
                debug: [
                  short: "-d",
                  long: "--debug",
                  help: "Enable debug logging"
                ]
              ],
              options: [
                type: [
                  short: "-t",
                  long: "--type",
                  value_name: "TYPE",
                  help: "Seed type (nixos, home-manager, nix-darwin, service)",
                  required: true,
                  parser: &parse_seed_type/1
                ],
                name: [
                  short: "-n",
                  long: "--name",
                  value_name: "NAME",
                  help: "Seed name",
                  required: true
                ],
                tag: [
                  short: "-T",
                  long: "--tag",
                  value_name: "KEY=VALUE",
                  help: "Filter by tag (can be repeated)",
                  multiple: true
                ]
              ]
            ],
            info: [
              name: "info",
              about: "Get information about latest seed",
              flags: [
                debug: [
                  short: "-d",
                  long: "--debug",
                  help: "Enable debug logging"
                ]
              ],
              options: [
                type: [
                  short: "-t",
                  long: "--type",
                  value_name: "TYPE",
                  help: "Seed type (nixos, home-manager, nix-darwin, service)",
                  required: true,
                  parser: &parse_seed_type/1
                ],
                name: [
                  short: "-n",
                  long: "--name",
                  value_name: "NAME",
                  help: "Seed name",
                  required: true
                ],
                tag: [
                  short: "-T",
                  long: "--tag",
                  value_name: "KEY=VALUE",
                  help: "Filter by tag (can be repeated)",
                  multiple: true
                ]
              ]
            ],
            upgrade: [
              name: "upgrade",
              about: "Download and activate a seed",
              flags: [
                debug: [
                  short: "-d",
                  long: "--debug",
                  help: "Enable debug logging"
                ]
              ],
              options: [
                type: [
                  short: "-t",
                  long: "--type",
                  value_name: "TYPE",
                  help: "Seed type (nixos, home-manager, nix-darwin, service)",
                  required: true,
                  parser: &parse_seed_type/1
                ],
                name: [
                  short: "-n",
                  long: "--name",
                  value_name: "NAME",
                  help: "Seed name",
                  required: true
                ],
                mode: [
                  short: "-m",
                  long: "--mode",
                  value_name: "MODE",
                  help: "Activation mode (e.g., switch, boot, test)",
                  required: false
                ],
                tag: [
                  short: "-T",
                  long: "--tag",
                  value_name: "KEY=VALUE",
                  help: "Filter by tag (can be repeated)",
                  multiple: true
                ]
              ]
            ]
          ]
        ]
      ]
    )
  end

  defp version do
    @version
  end

  defp parse_nix_type("auto"), do: {:ok, :auto}
  defp parse_nix_type("flake"), do: {:ok, :flake}
  defp parse_nix_type("path"), do: {:ok, :path}

  defp parse_nix_type(other) do
    {:error, "invalid type '#{other}', expected: auto, flake, or path"}
  end

  defp parse_seed_type(type) do
    if type in SowerClient.Seed.seed_types() do
      {:ok, type}
    else
      {:error,
       "invalid seed type '#{type}', expected: #{Enum.join(SowerClient.Seed.seed_types(), ", ")}"}
    end
  end
end
