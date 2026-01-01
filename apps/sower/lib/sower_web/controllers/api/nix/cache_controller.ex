defmodule SowerWeb.Api.Nix.CacheController do
  use SowerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias OpenApiSpex.Schema
  import Sower.Authorization

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  action_fallback SowerWeb.Api.FallbackController

  operation(:list,
    operation_id: "ListNixCaches",
    summary: "List Nix Caches",
    responses: [
      ok:
        {"Nix Cache response", "application/json",
         %Schema{type: :array, items: SowerClient.Nix.Cache}},
      unauthorized:
        {"Unauthorized", "application/json",
         %Schema{type: :object, properties: %{error: %Schema{type: :string}}}}
    ]
  )

  def list(conn, _) do
    if can(conn.assigns.access_token)
       |> read?(%Sower.Nix.Cache{org_id: conn.assigns.access_token.org_id}) do
      caches = Sower.Nix.list_nix_caches()
      render(conn, :list, caches: caches)
    else
      conn |> put_status(401) |> render(:error, error: "unauthorized")
    end
  end
end
