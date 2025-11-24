defmodule SowerClient do
  def spec() do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{
        title: "SowerClient",
        version: to_string(Application.spec(:sower, :vsn))
      },
      paths: %{},
      components: nil
    }
    |> OpenApiSpex.resolve_schema_modules()
    |> OpenApiSpex.add_schemas([
      SowerClient.Schemas.AgentHello,
      SowerClient.Schemas.Orchestration.Subscription,
      SowerClient.Schemas.Orchestration.DeploymentRequest
    ])
  end
end
