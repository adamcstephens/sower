defmodule SowerClient.Schemas.Orchestration.Subscription do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "Subscription",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "subscription sid allocated by Sower",
        readOnly: true,
        nullable: true
      },
      seed_name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: SowerClient.Schemas.Seed.seed_types()
      }
    },
    required: []
  })
end
