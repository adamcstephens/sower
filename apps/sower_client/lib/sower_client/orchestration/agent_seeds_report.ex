defmodule SowerClient.Orchestration.AgentSeedsReport do
  @moduledoc """
  Container for all Nix profiles reported by an agent.
  Sent when agent connects and after deployments complete.
  """
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "agent:seeds:report"

  OpenApiSpex.schema(%{
    title: "AgentSeedsReport",
    type: :object,
    properties: %{
      profiles: %Schema{
        type: :array,
        items: SowerClient.Orchestration.AgentSeedProfile,
        description: "All Nix profiles with their generations"
      }
    },
    required: [:profiles]
  })
end
