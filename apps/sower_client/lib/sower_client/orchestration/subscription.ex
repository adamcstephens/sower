defmodule SowerClient.Orchestration.Subscription do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "subscription:register"

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
      name: %Schema{
        type: :string,
        description: "Human-readable subscription name"
      },
      seed_name: %Schema{
        type: :string,
        description: "Name of the seed",
        example: "myhost",
        nullable: false
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: SowerClient.Seed.seed_types(),
        example: "nixos",
        nullable: false
      },
      rules: %Schema{
        type: :array,
        items: __MODULE__.Rule,
        default: [],
        description: "Tag-based rules to filter seeds"
      },
      schedule: %Schema{
        type: :string,
        description: "Cron expression for polling schedule",
        nullable: true
      },
      timezone: %Schema{
        type: :string,
        description: "IANA timezone for schedule evaluation",
        nullable: true
      },
      policy: %Schema{
        type: :object,
        additionalProperties: __MODULE__.Policy,
        default: %{},
        description:
          "Policy rules controlling when and how deployment actions are permitted, keyed by rule name"
      }
    },
    required: [:name, :seed_name, :seed_type],
    example: %{
      seed_name: "myhost",
      seed_type: "nixos",
      rules: [
        %{key: "branch", op: "eq", value: "main"},
        %{key: "repo", op: "eq", value: "https://github.com/example/repo"}
      ]
    }
  })

  defmodule Rule do
    use SowerClient.Schema

    OpenApiSpex.schema(%{
      title: "SubscriptionRule",
      type: :object,
      properties: %{
        key: %Schema{
          type: :string,
          description: "tag key",
          example: "branch"
        },
        op: %Schema{
          type: :string,
          description: "operation to apply",
          enum: ["eq"]
        },
        value: %Schema{
          type: :string,
          description: "value",
          example: "main"
        }
      },
      required: [:key, :op, :value]
    })
  end
end
