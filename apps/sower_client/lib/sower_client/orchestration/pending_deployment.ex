defmodule SowerClient.Orchestration.PendingDeployment do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "PendingDeployment",
    type: :object,
    properties: %{
      seed_sid: %Schema{type: :string},
      seed_url: %Schema{type: :string}
    },
    required: [:seed_sid, :seed_url]
  })
end
