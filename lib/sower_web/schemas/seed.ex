defmodule SowerWeb.Schemas.Seed do
  require OpenApiSpex

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Seed",
    description: "A seed is an installable unit",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "sid of the seed",
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
      "id" => "example4ser3adju75ddusbr",
      "name" => "myhost",
      "seed_type" => "nixos"
    }
  })
end
