defmodule SowerClient.Orchestration.SeedDeploymentResult do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "deployment:seed_result"

  OpenApiSpex.schema(%{
    title: "SeedDeploymentResult",
    type: :object,
    properties: %{
      deployment_sid: %Schema{
        type: :string,
        description: "deployment sid which is being reported on"
      },
      seed_sid: %Schema{
        type: :string,
        description: "seed sid which is being reported on"
      },
      result: %Schema{
        type: :string,
        description: "result of the seed deployment",
        enum: [:success, :failure],
        nullable: true
      },
      log: %Schema{
        type: :string,
        description: "deployment log output for this seed",
        default: ""
      }
    },
    required: [:deployment_sid, :seed_sid]
  })
end
