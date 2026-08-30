defmodule SowerClient.Admin.StatusReport do
  @moduledoc """
  Garden status returned on the ok frame of a `status` admin request.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminStatusReport",
    type: :object,
    properties: %{
      version: %Schema{
        type: :string,
        description: "Running garden version"
      },
      active_deployments: %Schema{
        type: :array,
        items: %Schema{type: :string},
        default: [],
        description: "Sids of deployments currently inflight"
      },
      credentials_rejected_at: %Schema{
        type: :string,
        nullable: true,
        description:
          "When set, the server rejected this garden's credentials at this time and it is awaiting operator re-registration"
      }
    },
    required: [:version]
  })
end
