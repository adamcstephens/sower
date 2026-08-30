defmodule SowerClient.Admin.Reregister do
  @moduledoc """
  `reregister` command payload for the garden admin socket — no fields; discards
  the garden's identity and enrolls a new one. This is the operator-triggered
  recovery path for a garden whose credentials the server has rejected.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminReregister",
    type: :object,
    properties: %{},
    required: []
  })
end
