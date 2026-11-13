defmodule SowerClient.Admin.DeployWait do
  @moduledoc """
  Opt-in deployment-start observation on the local garden admin socket.

  A distinct command makes older gardens reject waiting without enqueuing work.
  The timeout bounds observation only; it never cancels deployment work.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminDeployWait",
    type: :object,
    properties: %{
      seed_type: %Schema{type: :string, enum: SowerClient.Seed.seed_types(), nullable: true},
      sid: %Schema{type: :string, nullable: true},
      force: %Schema{type: :boolean, default: false},
      timeout: %Schema{type: :integer, minimum: 1, maximum: 86400, default: 30}
    },
    required: []
  })
end
