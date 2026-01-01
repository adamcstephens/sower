defmodule SowerClient.AgentHello do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "agent:hello", topic_type: :lobby

  OpenApiSpex.schema(%{
    title: "AgentHello",
    type: :object,
    properties: %{
      agent_sid: %Schema{
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
        description: "Name of agent"
      }
    },
    required: ~w(local_sid name)a
  })
end
