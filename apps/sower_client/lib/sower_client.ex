defmodule SowerClient do
  # Schemas the server pushes TO gardens (broadcasts + replies).
  # Changes to these can break old gardens that haven't upgraded.
  # Used by contract evolution tests and baseline generation.
  @server_pushed_schema_titles [
    "Deployment",
    "OAuthCredentials",
    "SeedDeployment",
    "Seed",
    "SeedTag",
    "PresignedUploadReply"
  ]

  def server_pushed_schema_titles, do: @server_pushed_schema_titles

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
      SowerClient.GardenHello,
      SowerClient.GardenRegistration,
      SowerClient.AgentHello,
      SowerClient.GardenRekey,
      SowerClient.Auth.OAuthCredentials,
      SowerClient.Auth.TokenInfo,
      SowerClient.Orchestration.GardenSeedGeneration,
      SowerClient.Orchestration.GardenSeedProfile,
      SowerClient.Orchestration.GardenSeedsReport,
      SowerClient.Orchestration.AgentSeedGeneration,
      SowerClient.Orchestration.AgentSeedProfile,
      SowerClient.Orchestration.AgentSeedsReport,
      SowerClient.Orchestration.Deployment,
      SowerClient.Orchestration.DeploymentResult,
      SowerClient.Orchestration.DeploymentRequest,
      SowerClient.Orchestration.DeploymentStatus,
      SowerClient.Orchestration.SeedDeployment,
      SowerClient.Orchestration.SeedDeploymentResult,
      SowerClient.Orchestration.SeedDeploymentStatus,
      SowerClient.Orchestration.Subscription,
      SowerClient.Orchestration.Subscription.Window,
      SowerClient.Orchestration.SubscriptionSync,
      SowerClient.Storage.PresignedUploadReply,
      SowerClient.Storage.DeploymentLogUploadRequest,
      SowerClient.Seed,
      SowerClient.SeedMeta,
      SowerClient.SeedTag
    ])
    |> OpenApiSpex.resolve_schema_modules()
  end
end
