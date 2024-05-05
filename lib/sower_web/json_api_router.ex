defmodule SowerWeb.JsonApiRouter do
  use AshJsonApi.Router,
    domains: [Module.concat(["Sower"])],
    json_schema: "/json_schema",
    open_api: "/open_api"
end
