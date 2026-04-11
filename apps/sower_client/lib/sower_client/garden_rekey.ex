defmodule SowerClient.GardenRekey do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "GardenRekey",
    description: "Request to re-key a garden's OAuth client",
    type: :object,
    properties: %{
      public_key: %Schema{
        type: :string,
        description: "PEM-encoded RSA public key for private_key_jwt authentication"
      }
    },
    required: [:public_key]
  })
end
