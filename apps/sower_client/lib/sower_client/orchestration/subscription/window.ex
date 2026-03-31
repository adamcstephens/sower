defmodule SowerClient.Orchestration.Subscription.Window do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SubscriptionWindow",
    type: :object,
    nullable: true,
    properties: %{
      days: %Schema{
        type: :array,
        items: %Schema{
          type: :string,
          enum: ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
        },
        description: "Days of the week when deployments are allowed"
      },
      time_start: %Schema{
        type: :string,
        description: "Start of deployment window (HH:MM)",
        example: "09:00"
      },
      time_end: %Schema{
        type: :string,
        description: "End of deployment window (HH:MM)",
        example: "17:00"
      },
      tz: %Schema{
        type: :string,
        description: "IANA timezone for window evaluation",
        example: "America/New_York"
      }
    },
    required: [:days, :time_start, :time_end, :tz]
  })
end
