defmodule SowerClient.Storage.DeploymentLogUploadRequest do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "storage:deployment_log_upload"

  OpenApiSpex.schema(%{
    title: "DeploymentLogUploadRequest",
    type: :object,
    properties: %{
      deployment_sid: %Schema{
        type: :string,
        description: "SID of the deployment the log belongs to"
      },
      seed_sid: %Schema{
        type: :string,
        description: "SID of the seed within the deployment"
      },
      checksum_sha256: %Schema{
        type: :string,
        description: "Base64 SHA-256 checksum to sign for upload integrity",
        nullable: true
      }
    },
    required: [:deployment_sid, :seed_sid]
  })
end
