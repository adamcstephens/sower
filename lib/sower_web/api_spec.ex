defmodule SowerWeb.ApiSpec do
  alias OpenApiSpex.{Info, OpenApi, Paths, Server}
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
        Server.from_endpoint(Endpoint)
      ]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
