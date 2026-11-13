defmodule SowerClient.Orchestration.GardenSeedGeneration do
  @moduledoc """
  Represents a single Nix profile generation reported by a garden.
  """
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "GardenSeedGeneration",
    type: :object,
    properties: %{
      generation_id: %Schema{type: :string, nullable: true},
      seed_sid: %Schema{type: :string, nullable: true},
      generation_path: %Schema{type: :string, nullable: true},
      is_staged: %Schema{type: :boolean, default: false},
      pinned: %Schema{type: :boolean, default: false},
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
