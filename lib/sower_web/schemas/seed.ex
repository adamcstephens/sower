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
        description: "id of the seed",
        readOnly: true
      },
      name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: ["nixos", "home-manager", "nix-darwin"]
      }
    },
    required: ~w(name seed_type)a,
    example: %{
      "id" => "1234-5678-1234-5678",
      "name" => "myhost",
      "seed_type" => "nixos"
    }
  })
end
