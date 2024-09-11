defmodule SowerWeb.Schemas.Seed do
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Seed",
    description: "A seed is an installable unit",
    type: :object,
    properties: %{
      id: %Schema{
        type: :string,
        format: :uuid,
        description: "Name of the seed",
        readOnly: true
      },
      name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed"
      }
    },
    required: ~w(name seed_type store_path)a,
    example: %{
      "name" => "myhost",
      "seed_type" => "nixos"
    }
  })
end
