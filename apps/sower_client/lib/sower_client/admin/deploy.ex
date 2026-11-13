defmodule SowerClient.Admin.Deploy do
  @moduledoc """
  `deploy` command payload for the garden admin socket.

  Either `seed_type` or `sid` scopes the deployment; the garden rejects a deploy
  carrying neither. By default the command observes authoritative execution starts
  for up to 30 seconds. `wait: false` returns after enqueuing. The timeout ends
  observation only, never deployment work.
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
      },
      wait: %Schema{
        type: :boolean,
        default: true,
        description: "Wait for authoritative per-seed execution starts, not completion"
      },
      timeout: %Schema{
        type: :integer,
        minimum: 1,
        maximum: 86400,
        default: 30,
        description: "Maximum observation time in seconds; unused when wait is false"
      }
    },
    required: []
  })
end
