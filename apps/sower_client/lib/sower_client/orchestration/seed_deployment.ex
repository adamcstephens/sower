defmodule SowerClient.Orchestration.SeedDeployment do
  use SowerClient.Schema

  def log_path(deployment_sid, seed_sid) do
    "logs/deployments/#{deployment_sid}/seeds/#{seed_sid}.log"
  end

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
