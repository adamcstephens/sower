defmodule SowerClient.Schemas.Seed do
  use SowerClient.Schema

  @seed_types ["nixos", "home-manager", "nix-darwin", "service"]

  OpenApiSpex.schema(%{
    title: "Seed",
    description: "A seed is an installable unit",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "sid of the seed set by the server",
        readOnly: true
      },
      name: %Schema{
        type: :string,
        description: "Name of the seed"
      },
      seed_type: %Schema{
        type: :string,
        description: "Type of the seed",
        enum: @seed_types
      },
      artifact: %Schema{
        type: :string,
        description: "Artifact of the seed"
      },
      tags: %Schema{
        type: :array,
        description: "Tags associated with the seed",
        items: SowerClient.Schemas.SeedTag
      }
    },
    required: [:name, :seed_type, :artifact],
    example: %{
      "sid" => "example4ser3adju75ddusbr",
      "name" => "myhost",
      "seed_type" => "nixos",
      "artifact" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos",
      "tags" => []
    }
  })

  def seed_types() do
    @seed_types
  end
end
