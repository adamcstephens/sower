defmodule SowerClient.Orchestration.DeploymentStatus do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "deployment:status"

  OpenApiSpex.schema(%{
    title: "DeploymentStatus",
    type: :object,
    properties: %{
      deployment_sid: %Schema{
        type: :string,
        description: "deployment sid which is being reported on"
      },
      status: %Schema{
        type: :string,
        description: "deployment-level status",
        enum: [:acknowledged]
      }
    },
    required: [:deployment_sid, :status]
  })
end
