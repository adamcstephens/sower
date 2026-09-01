defmodule SowerClient.Orchestration.SeedDeployment do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SeedDeployment",
    type: :object,
    properties: %{
      seed: SowerClient.Seed,
      subscription_sid: %Schema{
        type: :string,
        description: "subscription sid associated with seed",
        nullable: true
      },
      action: %Schema{
        type: :string,
        enum: SowerClient.Orchestration.Subscription.Policy.actions(),
        description:
          "Action the server authorized for this seed. The garden clamps it to what its own policy permits.",
        nullable: true
      }
    },
    required: []
  })
end
