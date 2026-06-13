defmodule SowerCli.Seed.Info do
  @moduledoc """
  Display information about the latest seed matching criteria.

  Queries the server for a seed matching name, type, and optional tags,
  then displays its metadata without downloading or activating.
  """

  alias SowerCli.{Auth, Output}

  def run(flags, options) do
    Output.init(debug: flags.debug)
    Application.ensure_all_started([:req])

    with :ok <- Auth.verify_connection(),
         {:ok, seed} <- fetch_seed(options) do
      display_seed(seed)
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
        {:ok, seed}

      {:error, "not found"} ->
        Output.error("No seed found matching criteria")
        {:error, :not_found}

      {:error, reason} ->
        Output.error("Failed to fetch seed: #{inspect(reason)}")
        {:error, {:fetch_failed, reason}}
    end
  end

  defp display_seed(%SowerClient.Seed{} = seed) do
    Output.info("")
    Output.info("Name:     #{seed.name}")
    Output.info("Type:     #{seed.seed_type}")
    Output.info("Artifact: #{seed.artifact}")

    unless Enum.empty?(seed.tags) do
      Output.info("Tags:     #{format_seed_tags(seed.tags)}")
    end

    Output.info("")
  end

  defp format_seed_tags(tags) do
    tags
    |> Enum.map(fn tag -> "#{tag.key}=#{tag.value}" end)
    |> Enum.join(", ")
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
