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
          "Action the server authorized for this seed. The garden applies local policy unless override is authorized.",
        nullable: true
      },
      override: %Schema{
        type: :boolean,
        default: false,
        description: "Server-authorized direct deployment override of local deployment policy"
      }
    },
    required: []
  })
end
