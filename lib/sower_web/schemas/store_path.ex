defmodule SowerWeb.Schemas.StorePath do
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "StorePath",
    description: "A store path is a Nix store path that can by installed by a client",
    type: :object,
    properties: %{
      id: %Schema{
        type: :string,
        format: :uuid,
        description: "id of the store path",
        readOnly: true
      },
      path: %Schema{
        type: :string,
        description: "Store path itself"
      }
    },
    required: ~w(path)a,
    example: %{
      "path" => "/nix/store/..."
    }
  })
end
