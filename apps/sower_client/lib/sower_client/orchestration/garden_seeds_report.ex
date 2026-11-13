defmodule SowerClient.Orchestration.GardenSeedsReport do
  @moduledoc """
  Container for all Nix profiles reported by a garden.
  Sent when garden connects and after deployments complete.
  """
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "garden:seeds:report"

  OpenApiSpex.schema(%{
    title: "GardenSeedsReport",
    type: :object,
    properties: %{
      complete: %Schema{type: :boolean, nullable: true},
      failed_profile_paths: %Schema{
        type: :array,
        items: %Schema{type: :string},
        default: []
      },
      profiles: %Schema{
        type: :array,
        items: SowerClient.Orchestration.GardenSeedProfile,
        description: "All Nix profiles with their generations"
      }
    },
    required: [:profiles]
  })
end
