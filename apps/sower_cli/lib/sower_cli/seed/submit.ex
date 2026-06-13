defmodule SowerCli.Seed.Submit do
  @moduledoc """
  Submit a seed to the server.

  Registers a Nix store path as a seed with the given name, type, and optional tags.
  """

  alias SowerCli.{Auth, Output}

  def run(flags, options) do
    Output.init(debug: flags.debug)
    Application.ensure_all_started([:req])

    with :ok <- Auth.verify_connection(),
         {:ok, seed} <- submit_seed(options) do
      Output.success("Seed registered: #{seed.name} (#{seed.seed_type}) -> #{seed.artifact}")
      :ok
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp submit_seed(options) do
    tags = parse_tags(options.tag || [])

    seed = %SowerClient.Seed{
      name: options.name,
      seed_type: options.type,
      artifact: options.artifact,
      tags: tags
    }

    Output.step("Submitting seed #{seed.name} (#{seed.seed_type})")

    case SowerClient.Seed.create(seed, []) do
      {:ok, %SowerClient.Seed{} = registered} ->
        {:ok, registered}

      {:error, reason} ->
        Output.error("Failed to submit seed: #{inspect(reason)}")
        {:error, {:submit_failed, reason}}
    end
  end

  defp parse_tags(tag_strings) do
    Enum.map(tag_strings, &SowerClient.SeedTag.from_string/1)
  end
end
