defmodule SowerClient.Orchestration.SeedDeploymentStatus do
  @moduledoc "Progress for one seed destination; managed profiles require subscription identity."
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "deployment:seed_status"

  OpenApiSpex.schema(%{
    title: "SeedDeploymentStatus",
    type: :object,
    properties: %{
      subscription_sid: %Schema{type: :string, nullable: true},
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
