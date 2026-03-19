defmodule SowerClient.Orchestration.SeedDeploymentStatus do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "deployment:seed_status"

  OpenApiSpex.schema(%{
    title: "SeedDeploymentStatus",
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
      status: %Schema{
        type: :string,
        description: "seed deployment progress status",
        enum: [:downloading, :activating, :completed]
      }
    },
    required: [:deployment_sid, :seed_sid, :status]
  })
end
