defmodule SowerClient.Admin.Reload do
  @moduledoc """
  `reload` command payload for the garden admin socket — no fields; maps to the
  same path as a SIGHUP.
  """

  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "AdminReload",
    type: :object,
    properties: %{},
    required: []
  })
end
