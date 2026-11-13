defmodule SowerClient.Orchestration.SeedDeployment do
  @moduledoc "An authorized seed deployment with an explicit subscription and optional managed profile destination."
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SeedDeployment",
    type: :object,
    properties: %{
      seed: SowerClient.Seed,
      profile_name: %Schema{type: :string, nullable: true},
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
