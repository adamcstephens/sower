defmodule SowerClient.SeedMeta do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SeedMeta",
    description: "Seed metadata from nix derivation",
    type: :object,
    properties: %{
      seed: SowerClient.Seed
    },
    required: [:seed]
  })
end
