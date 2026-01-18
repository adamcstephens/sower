defmodule SowerClient.Orchestration.AgentSeedGeneration do
  @moduledoc """
  Represents a single Nix profile generation reported by an agent.
  """
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AgentSeedGeneration",
    type: :object,
    properties: %{
      path: %Schema{
        type: :string,
        description: "The Nix store path (e.g., /nix/store/abc-nixos-system)"
      },
      link: %Schema{
        type: :string,
        description: "The symlink path (e.g., /nix/var/nix/profiles/system-42-link)"
      },
      created: %Schema{
        type: :string,
        format: :"date-time",
        description: "When the Nix generation was created"
      },
      generation_number: %Schema{
        type: :integer,
        description: "Nix generation number (extracted from link)",
        nullable: true
      },
      is_current: %Schema{
        type: :boolean,
        description: "Is this the active generation?",
        default: false
      }
    },
    required: [:path, :link, :created, :is_current]
  })
end
