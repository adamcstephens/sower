defmodule SowerClient.Orchestration.DeploymentError do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "deployment:error"

  OpenApiSpex.schema(%{
    title: "DeploymentError",
    type: :object,
    properties: %{
      request_id: %Schema{type: :string, description: "Original request ID"},
      reason: %Schema{type: :string, description: "Error reason"}
    },
    required: ~w(request_id reason)a
  })
end
