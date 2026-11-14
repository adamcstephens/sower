defmodule SowerClient.Orchestration.PendingDeployment do
  @moduledoc "Seed identity and optional server metadata for pending or running work."

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "PendingDeployment",
    type: :object,
    properties: %{
      seed_sid: %Schema{type: :string},
      seed_url: %Schema{type: :string},
      name: %Schema{type: :string, nullable: true},
      seed_type: %Schema{type: :string, nullable: true},
      updated_at: %Schema{type: :string, format: :date_time, nullable: true}
    },
    required: [:seed_sid, :seed_url]
  })
end
