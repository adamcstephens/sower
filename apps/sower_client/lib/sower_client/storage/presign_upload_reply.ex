defmodule SowerClient.Storage.PresignUploadReply do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "PresignUploadReply",
    type: :object,
    properties: %{
      url: %Schema{
        type: :string,
        description: "Signed URL for direct upload"
      },
      method: %Schema{
        type: :string,
        description: "HTTP method to use for upload",
        default: "PUT"
      },
      headers: %Schema{
        type: :object,
        description: "Headers that must be sent with upload request",
        default: %{},
        additionalProperties: %Schema{type: :string}
      }
    },
    required: [:url, :method, :headers]
  })
end
