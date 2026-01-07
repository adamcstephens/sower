defmodule SowerCli.Seed.Download do
  @moduledoc """
  Download and realize a seed from the server.

  Workflow:
  1. Validate server connection config
  2. Query server for latest seed matching name, type, and tags
  3. Check if artifact exists locally
  4. If not, realize it using nix-store
  5. Report success/failure
  """

  require Logger

  alias SowerCli.{Config, Output}

  def run(flags, options) do
    Output.init(debug: flags.debug)
    Application.ensure_all_started([:req])

    config = Config.get()

    with :ok <- validate_config(config),
         {:ok, seed} <- fetch_seed(options),
         {:ok, _} <- ensure_realized(seed) do
      Output.success("Seed available at #{seed.artifact}")
      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_config(%SowerClient.Config{} = config) do
    try do
      Config.require_server_connection!(config)
      :ok
    rescue
      e in ArgumentError ->
        Output.error(e.message)
        {:error, :missing_server_config}
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

  defp ensure_realized(%SowerClient.Seed{} = seed) do
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

  defp parse_tags(tag_strings) do
    Enum.map(tag_strings, &SowerClient.SeedTag.from_string/1)
  end

  defp format_tags(tags) do
    tags
    |> Enum.map(&SowerClient.SeedTag.to_query_string/1)
    |> Enum.join(", ")
  end
end
