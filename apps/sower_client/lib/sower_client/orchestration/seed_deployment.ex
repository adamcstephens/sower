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
      }
    },
    required: []
  })
end
