defmodule SowerCli.Seed.Upgrade do
  @moduledoc """
  Download and activate a seed.
  """

  require Logger

  alias SowerCli.{Auth, Output}

  def run(flags, options) do
    Output.init(debug: flags.debug)
    Application.ensure_all_started([:req])

    with :ok <- Auth.verify_connection(),
         {:ok, seed} <- fetch_seed(options),
         {:ok, _} <- realize_seed(seed),
         {:ok, _} <- activate_seed(seed, options) do
      Output.success("Successfully activated: #{seed.artifact}")
      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_seed(options) do
    name = options.name
    seed_type = options.type
    tags = parse_tags(options.tag || [])

    Output.step("Fetching seed #{name} (#{seed_type})")

    result =
      if Enum.empty?(tags) do
        SowerClient.Seed.latest(name, seed_type)
      else
        Output.info("Filtering by tags: #{format_tags(tags)}")
        SowerClient.Seed.latest(name, seed_type, tags)
      end

    case result do
      {:ok, %SowerClient.Seed{} = seed} ->
        Output.success("Found seed: #{seed.artifact}")
        {:ok, seed}

      {:error, "not found"} ->
        Output.error("No seed found matching criteria")
        {:error, :not_found}

      {:error, reason} ->
        Output.error("Failed to fetch seed: #{inspect(reason)}")
        {:error, {:fetch_failed, reason}}
    end
  end

  defp realize_seed(%SowerClient.Seed{} = seed) do
    artifact = seed.artifact

    if File.exists?(artifact) do
      Output.info("Artifact already exists locally")
      {:ok, :already_exists}
    else
      Output.step("Realizing #{artifact}")

      case Nix.Store.realize(artifact) do
        {:ok, _lines} ->
          Output.success("Successfully realized artifact")
          {:ok, :realized}

        {:error, exit_code} ->
          Output.error("Failed to realize artifact (exit code: #{exit_code})")
          {:error, {:realize_failed, exit_code}}
      end
    end
  end

  defp activate_seed(%SowerClient.Seed{} = seed, options) do
    type = seed.seed_type
    path = seed.artifact
    mode = Map.get(options, :mode)

    Output.step("Activating #{type} configuration")

    on_output = fn line ->
      Output.info("  #{line}")
    end

    opts = [on_output: on_output, tags: seed.tags]
    opts = if mode, do: Keyword.put(opts, :mode, mode), else: opts

    case SowerClient.Activator.activate(type, path, opts) do
      {:ok, _output} ->
        {:ok, :activated}

      {:error, :cmd_not_found} ->
        Output.error("Required executables not found: sudo and/or sower-activator")
        Output.error("Make sure sower-activator is installed and in PATH")
        {:error, :cmd_not_found}

      {:error, :socket_not_found} ->
        Output.error("Activator socket not found and CLI fallback failed")
        {:error, :activator_unavailable}

      {:error, exit_code, output} when is_integer(exit_code) ->
        Output.error("Activation failed with exit code #{exit_code}")

        unless Enum.empty?(output) do
          Output.error("Last output lines:")
          Enum.take(output, -5) |> Enum.each(&Output.error("  #{&1}"))
        end

        {:error, {:activation_failed, exit_code}}

      {:error, reason} ->
        Output.error("Activation failed: #{inspect(reason)}")
        {:error, {:activation_failed, reason}}
    end
  end

  defp parse_tags(tag_strings) do
    Enum.map(tag_strings, &SowerClient.SeedTag.from_string/1)
  end

  defp format_tags(tags) do
    tags
    |> Enum.map(&SowerClient.SeedTag.to_query_string/1)
    |> Enum.join(", ")
  end
end
