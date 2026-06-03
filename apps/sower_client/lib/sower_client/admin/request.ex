defmodule SowerClient.Admin.Request do
  @moduledoc """
  Request envelope for the garden admin socket (CLI -> garden).

  Newline-delimited compact JSON. `v` is the protocol version so the contract
  can evolve without changing the wire framing. These schemas are CLI<->garden
  only and are intentionally excluded from `SowerClient` server-pushed titles.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminRequest",
    type: :object,
    properties: %{
      v: %Schema{
        type: :integer,
        default: 1,
        description: "Protocol version"
      },
      id: %Schema{
        type: :string,
        description: "Request id, echoed back on every reply frame"
      },
      kind: %Schema{
        type: :string,
        enum: ["deploy", "reload", "status"],
        description: "Admin command to run"
      },
      seed_type: %Schema{
        type: :string,
        enum: SowerClient.Seed.seed_types(),
        nullable: true,
        description: "Scope a deploy to a seed type"
      },
      sid: %Schema{
        type: :string,
        nullable: true,
        description: "Scope a deploy to a single subscription sid"
      },
      force: %Schema{
        type: :boolean,
        default: false,
        description: "Force deployment even if identical to a previous success"
      }
    },
    required: [:id, :kind]
  })
end
