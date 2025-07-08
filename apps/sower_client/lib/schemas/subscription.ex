defmodule SowerClient.Schemas.Subscription do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "Subscription",
    type: :object,
    properties: %{
      local_sid: %Schema{
        type: :string,
        description: "sid allocated locally",
        default: "lsid_#{Cuid2Ex.create()}"
      },
      name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_sid: %Schema{
        type: :string,
        description: "seed sid allocated by Sower",
        readOnly: true,
        nullable: true
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: SowerClient.Schemas.Seed.seed_types()
      },
      subscription_sid: %Schema{
        type: :string,
        description: "subscription sid allocated by Sower",
        readOnly: true,
        nullable: true
      }
    },
    required: ~w(name seed_type)a
  })
end
