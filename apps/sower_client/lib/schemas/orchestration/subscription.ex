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
      },
      rules: %Schema{
        type: :array,
        items: __MODULE__.Rule,
        nullable: true
      }
    },
    required: []
  })

  defmodule Rule do
    use SowerClient.Schema

    OpenApiSpex.schema(%{
      title: "SubscriptionRule",
      type: :object,
      properties: %{
        key: %Schema{
          type: :string,
          description: "tag key"
        },
        op: %Schema{
          type: :string,
          description: "operation to apply"
        },
        value: %Schema{
          type: :string,
          description: "value"
        }
      },
      required: [:key, :op, :value]
    })
  end
end
