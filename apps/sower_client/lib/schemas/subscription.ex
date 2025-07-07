defmodule SowerClient.Schemas.Subscription do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AgentHello",
    type: :object,
    properties: %{
      seed_sid: %Schema{
        type: :string,
        description: "sid allocated by Sower",
        readOnly: true,
        nullable: true
      },
      local_sid: %Schema{
        type: :string,
        description: "sid allocated locally",
        default: "lsubsid_#{Cuid2Ex.create()}"
      },
      name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: SowerClient.Schemas.Seed.seed_types()
      }
    },
    required: ~w(name seed_type)a
  })
end
