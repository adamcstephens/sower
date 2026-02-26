defmodule SowerClient.Storage.PresignedUploadReply do
  use SowerClient.Schema

  @moduledoc """
  Generic reply for presigned upload URL requests.

  Used across different upload contexts (deployment logs, etc.).
  Contains the URL, HTTP method, and required headers for the upload.
  """

  OpenApiSpex.schema(%{
    title: "PresignedUploadReply",
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
