defmodule SowerClient.Admin.Reply do
  @moduledoc """
  Reply frame for the garden admin socket (garden -> CLI).

  Mirrors the activator's Output/Error/Complete shape: `ok`/`error` frames carry
  data (and `status` for a `status` request), then a terminal `complete` frame
  carries the exit code the CLI exits with.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminReply",
    type: :object,
    properties: %{
      v: %Schema{
        type: :integer,
        default: 1,
        description: "Protocol version"
      },
      id: %Schema{
        type: :string,
        description: "Request id this frame replies to"
      },
      kind: %Schema{
        type: :string,
        enum: ["ok", "error", "complete"],
        description: "Frame type"
      },
      data: %Schema{
        type: :string,
        nullable: true,
        description: "Human-readable message"
      },
      exit_code: %Schema{
        type: :integer,
        nullable: true,
        description: "Exit code, present on the terminal complete frame"
      },
      status: SowerClient.Admin.Status
    },
    required: [:id, :kind]
  })
end
