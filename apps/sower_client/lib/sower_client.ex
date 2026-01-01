defmodule SowerClient do
  def spec() do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{
        title: "SowerClient",
        version: to_string(Application.spec(:sower, :vsn))
      },
      paths: %{},
      components: %OpenApiSpex.Components{schemas: %{}}
    }
    |> OpenApiSpex.add_schemas([
      SowerClient.AgentHello,
      SowerClient.Orchestration.Deployment,
      SowerClient.Orchestration.DeploymentResult,
      SowerClient.Orchestration.DeploymentRequest,
      SowerClient.Orchestration.Subscription,
      SowerClient.Seed,
      SowerClient.SeedTag
    ])
    |> OpenApiSpex.resolve_schema_modules()
  end
end
