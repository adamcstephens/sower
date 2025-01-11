defmodule SowerWeb.ApiSpec do
  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias SowerWeb.{Endpoint, Router}
  @behaviour OpenApi

  def spec() do
    %OpenApi{
      info: %Info{
        title: to_string(Application.spec(:sower, :description)),
        version: to_string(Application.spec(:sower, :vsn))
      },
      paths: Paths.from_router(Router),
      servers: [
        # variables unsupported by oooapi and were empty anyway
        Server.from_endpoint(Endpoint) |> Map.drop([:variables])
      ],
      components: %Components{
        securitySchemes: %{
          "authorization" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "sower",
            description: "sower api token"
          }
        }
      },
      security: [%{"authorization" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
