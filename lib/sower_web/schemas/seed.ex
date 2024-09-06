defmodule SowerWeb.Schemas.Seed do
  require OpenApiSpex

  alias OpenApiSpex.Schema

  defmodule Seed do
    OpenApiSpex.schema(%{
      title: "Seed",
      description: "A seed is an installable unit",
      type: :object,
      properties: %{
        name: %Schema{
          type: :string,
          description: "Name of the seed"
        },
        seed_type: %Schema{
          type: :string,
          description: "Type of the seed"
        },
        store_path: %Schema{
          type: :string,
          description: "Store path of the seed"
        }
      },
      required: ~w(name seed_type store_path)a,
      example: %{
        "name" => "myhost",
        "seed_type" => "nixos",
        "store_path" =>
          "/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-myhost-24.11.20240703.9f4128e"
      }
    })
  end

  defmodule Request do
    Seed
  end

  defmodule Response do
    OpenApiSpex.schema(%{
      title: "SeedResponse",
      description: "Resonse for a seed",
      type: :object,
      properties: %{data: Seed},
      example: %{
        "data" => %{
          "name" => "myhost",
          "seed_type" => "nixos",
          "store_path" =>
            "/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-myhost-24.11.20240703.9f4128e",
          "inserted_at" => "2017-09-12T12:34:55Z",
          "updated_at" => "2017-09-13T10:11:12Z"
        }
      }
    })
  end

  defmodule ListResponse do
    OpenApiSpex.schema(%{
      title: "SeedsResponse",
      description: "Response schema for multiple seeds",
      type: :object,
      properties: %{
        data: %Schema{description: "The seeds details", type: :array, items: Seed}
      },
      example: %{
        "data" => [
          %{
            "name" => "myhost",
            "seed_type" => "nixos",
            "store_path" =>
              "/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-myhost-24.11.20240703.9f4128e",
            "birthday" => "1970-01-01T12:34:55Z",
            "inserted_at" => "2017-09-12T12:34:55Z",
            "updated_at" => "2017-09-13T10:11:12Z"
          },
          %{
            "name" => "host3",
            "seed_type" => "nixos",
            "store_path" =>
              "/nix/store/fqf9pp2pbcv64j0bz3mwv5grj60jkvzv-nixos-system-host3-24.11.20240703.9f4128e",
            "birthday" => "1970-01-01T12:34:55Z",
            "inserted_at" => "2017-09-12T12:34:55Z",
            "updated_at" => "2017-09-13T10:11:12Z"
          }
        ]
      }
    })
  end
end
