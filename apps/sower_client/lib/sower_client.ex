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
      SowerClient.AgentHello,
      SowerClient.Orchestration.Deployment,
      SowerClient.Orchestration.DeploymentResult,
      SowerClient.Orchestration.DeploymentRequest,
      SowerClient.Orchestration.Subscription
    ])
  end
end
