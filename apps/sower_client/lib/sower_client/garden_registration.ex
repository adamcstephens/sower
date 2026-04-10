defmodule SowerClient.GardenRegistration do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "GardenRegistration",
    description: "HTTP registration request for a new garden",
    type: :object,
    properties: %{
      name: %Schema{
        type: :string,
        description: "Name of garden"
      },
      public_key: %Schema{
        type: :string,
        description: "PEM-encoded RSA public key for private_key_jwt authentication"
      }
    },
    required: [:name, :public_key]
  })
end
