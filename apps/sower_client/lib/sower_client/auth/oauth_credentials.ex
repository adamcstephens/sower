defmodule SowerClient.Auth.OAuthCredentials do
  use SowerClient.Schema

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OAuthCredentials",
    description: "OAuth credentials issued to a garden after registration",
    type: :object,
    properties: %{
      client_id: %Schema{
        type: :string,
        description: "Boruta OAuth client ID"
      },
      client_secret: %Schema{
        type: :string,
        description: "Boruta OAuth client secret"
      },
      access_token: %Schema{
        type: :string,
        description: "OAuth access token"
      },
      refresh_token: %Schema{
        type: :string,
        description: "OAuth refresh token for obtaining new access tokens"
      },
      expires_in: %Schema{
        type: :integer,
        description: "Access token TTL in seconds"
      },
      token_type: %Schema{
        type: :string,
        description: "Token type, typically bearer"
      }
    },
    required: [:client_id, :client_secret, :access_token, :refresh_token, :expires_in]
  })
end
