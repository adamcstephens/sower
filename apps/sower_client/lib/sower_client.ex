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
      SowerClient.Schemas.Orchestration.Deployment,
      SowerClient.Schemas.Orchestration.DeploymentResult,
      SowerClient.Schemas.Orchestration.DeploymentRequest,
      SowerClient.Schemas.Orchestration.Subscription
    ])
  end
end
