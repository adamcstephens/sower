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
      store_path: %Schema{
        type: :string,
        description: "Store path of the seed"
      }
    },
    required: ~w(name seed_type store_path)a,
    example: %{
      "id" => "example4ser3adju75ddusbr",
      "name" => "myhost",
      "seed_type" => "nixos",
      "store_path" => "/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-nixos"
    }
  })

  def seed_types() do
    @seed_types
  end
end
