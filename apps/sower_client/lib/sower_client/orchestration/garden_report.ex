defmodule SowerClient.Orchestration.GardenReport do
  @moduledoc """
  Garden-level facts a garden reports to the server.
  Sent when the garden joins its private channel.
  """
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "garden:report"

  OpenApiSpex.schema(%{
    title: "GardenReport",
    type: :object,
    properties: %{
      version: %Schema{
        type: :string,
        description: "Software version the garden is running"
      }
    },
    required: [:version]
  })
end
