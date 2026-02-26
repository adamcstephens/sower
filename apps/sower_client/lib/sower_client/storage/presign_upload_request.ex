defmodule SowerClient.Storage.PresignUploadRequest do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "storage:presign_upload"

  OpenApiSpex.schema(%{
    title: "PresignUploadRequest",
    type: :object,
    properties: %{
      path: %Schema{
        type: :string,
        description: "Path of object in storage bucket"
      },
      method: %Schema{
        type: :string,
        description: "HTTP method to be used with signed URL",
        default: "PUT"
      },
      checksum_sha256: %Schema{
        type: :string,
        description: "Base64 SHA-256 checksum to sign for upload integrity",
        nullable: true
      }
    },
    required: [:path]
  })
end
