defmodule SowerClient.Admin.Status do
  @moduledoc """
  `status` command payload for the garden admin socket — no fields; the garden
  replies with an `AdminStatusReport` on the ok frame.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminStatus",
    type: :object,
    properties: %{},
    required: []
  })
end
