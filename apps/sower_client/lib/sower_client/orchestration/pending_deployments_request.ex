defmodule SowerClient.Orchestration.PendingDeploymentsRequest do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "deployments:pending"

  OpenApiSpex.schema(%{
    title: "PendingDeploymentsRequest",
    type: :object,
    properties: %{},
    required: []
  })
end
