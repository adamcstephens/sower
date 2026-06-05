defmodule SowerClient.Admin.Deploy do
  @moduledoc """
  `deploy` command payload for the garden admin socket.

  Either `seed_type` or `sid` scopes the deployment; the garden rejects a deploy
  carrying neither.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminDeploy",
    type: :object,
    properties: %{
      seed_type: %Schema{
        type: :string,
        enum: SowerClient.Seed.seed_types(),
        nullable: true,
        description: "Scope the deployment to a seed type"
      },
      sid: %Schema{
        type: :string,
        nullable: true,
        description: "Scope the deployment to a single subscription sid"
      },
      force: %Schema{
        type: :boolean,
        default: false,
        description: "Force deployment even if identical to a previous success"
      }
    },
    required: []
  })
end
