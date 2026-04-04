defmodule SowerClient.Auth.OAuthCredentials do
  use SowerClient.Schema

  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "OAuthCredentials",
    description: "OAuth client registration returned to a garden after registration",
    type: :object,
    properties: %{
      client_id: %Schema{
        type: :string,
        description: "Boruta OAuth client ID"
      }
    },
    required: [:client_id]
  })
end
