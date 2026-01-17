defmodule SowerClient.Auth.TokenInfo do
  use SowerClient.Schema

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "TokenInfo",
    description: "Information about an authenticated access token",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "Token identifier"
      },
      description: %Schema{
        type: :string,
        description: "Human-readable token description"
      },
      permissions: %Schema{
        type: :array,
        items: %Schema{type: :string},
        description: "Permission roles (e.g., seed:read, seed:write)"
      },
      expires_at: %Schema{
        type: :string,
        format: :date,
        description: "Token expiration date"
      }
    },
    required: [:sid, :description, :permissions, :expires_at],
    example: %{
      "sid" => "example4ser3adju75ddusbr",
      "description" => "CI/CD token",
      "permissions" => ["seed:read", "seed:write"],
      "expires_at" => "2025-12-31"
    }
  })
end
