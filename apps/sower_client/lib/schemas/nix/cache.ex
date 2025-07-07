defmodule SowerClient.Schemas.Nix.Cache do
  alias OpenApiSpex.Schema
  require OpenApiSpex
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "Nix Cache",
    description: "A Nix binary cache",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "sid of the nix cache",
        readOnly: true
      },
      url: %Schema{
        type: :string,
        description: "URL to binary cache"
      },
      public_key: %Schema{
        type: :string,
        description: "Trusted public key for signed NARs"
      }
    },
    required: ~w(name seed_type)a,
    example: %{
      "sid" => "example4ser3adju75ddusbr",
      "url" => "https://my.cache.org",
      "public_key" => "my.cache.org:1111111111111111"
    }
  })
end
