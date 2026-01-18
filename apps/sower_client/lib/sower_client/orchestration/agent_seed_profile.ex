defmodule SowerClient.Orchestration.AgentSeedProfile do
  @moduledoc """
  Represents all generations for a single Nix profile on an agent.
  """
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AgentSeedProfile",
    type: :object,
    properties: %{
      profile_path: %Schema{
        type: :string,
        description: "The Nix profile path (e.g., /nix/var/nix/profiles/system)"
      },
      tags: %Schema{
        type: :object,
        additionalProperties: %Schema{type: :string},
        description: "Profile tags (e.g., %{user: alice} for HomeManager)",
        default: %{}
      },
      generations: %Schema{
        type: :array,
        items: SowerClient.Orchestration.AgentSeedGeneration,
        description: "All available generations for this profile"
      }
    },
    required: [:profile_path, :generations]
  })
end
