defmodule SowerWeb.Api.AuthController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.Api.FallbackController

  operation(:verify,
    operation_id: "VerifyToken",
    summary: "Verify access token",
    description: "Validates the Bearer token and returns token metadata",
    parameters: [],
    responses: %{
      ok: {"Token info response", "application/json", SowerClient.Auth.TokenInfo},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    }
  )

  def verify(conn, _params) do
    access_token = conn.assigns.access_token

    render(conn, :show, access_token: access_token)
  end
end
