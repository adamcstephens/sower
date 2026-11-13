defmodule SowerClient.Orchestration.GardenSeedProfile do
  @moduledoc """
  Represents all generations for a single Nix profile on a garden.
  """
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "GardenSeedProfile",
    type: :object,
    properties: %{
      name: %Schema{type: :string, nullable: true},
      subscription_sid: %Schema{type: :string, nullable: true},
      seed_type: %Schema{type: :string, nullable: true},
      managed: %Schema{type: :boolean, default: false},
      retention: %Schema{
        anyOf: [SowerClient.Orchestration.ProfileRetention],
        nullable: true,
        "x-struct": SowerClient.Orchestration.ProfileRetention
      },
      lifecycle_status: %Schema{
        type: :string,
        enum: ["installed", "staged", "uninstall_pending", "uninstall_blocked"],
        nullable: true
      },
      last_error: %Schema{type: :string, nullable: true},
      observed_at: %Schema{type: :string, format: :"date-time", nullable: true},
      stale: %Schema{type: :boolean, default: false},
      profile_path: %Schema{
        type: :string,
        nullable: true,
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
        items: SowerClient.Orchestration.GardenSeedGeneration,
        description: "All available generations for this profile"
      }
    },
    required: [:profile_path, :generations]
  })
end
