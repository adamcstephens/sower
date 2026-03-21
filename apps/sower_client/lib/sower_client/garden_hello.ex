defmodule SowerClient.GardenHello do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "garden:hello", topic_type: :lobby

  OpenApiSpex.schema(%{
    title: "GardenHello",
    type: :object,
    properties: %{
      garden_sid: %Schema{
        type: :string,
        description: "sid allocated by Sower",
        readOnly: true,
        nullable: true
      },
      local_sid: %Schema{
        type: :string,
        description: "sid allocated locally"
      },
      name: %Schema{
        type: :string,
        description: "Name of garden"
      }
    },
    required: [:local_sid, :name]
  })
end
