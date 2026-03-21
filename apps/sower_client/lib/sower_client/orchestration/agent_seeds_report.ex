# Deprecated: use SowerClient.Orchestration.GardenSeedsReport
# Kept as alias for 0.7.0 backward compatibility
defmodule SowerClient.Orchestration.AgentSeedsReport do
  @moduledoc """
  Deprecated: use SowerClient.Orchestration.GardenSeedsReport.
  Kept for backward compatibility with 0.7.0 gardens.
  """
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "agent:seeds:report"

  OpenApiSpex.schema(%{
    title: "AgentSeedsReport",
    type: :object,
    properties: %{
      profiles: %Schema{
        type: :array,
        items: SowerClient.Orchestration.GardenSeedProfile,
        description: "All Nix profiles with their generations"
      }
    },
    required: [:profiles]
  })
end
