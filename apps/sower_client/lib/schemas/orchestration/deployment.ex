defmodule SowerClient.Schemas.Orchestration.Deployment do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "Deployment",
    type: :object,
    properties: %{
      sid: %Schema{
        type: :string,
        description: "deployment sid allocated by Sower",
        readOnly: true
      },
      subscription_sid: %Schema{
        type: :string,
        description: "subscription sid allocated by Sower",
        readOnly: true
      },
      deployed_at: %Schema{
        type: :string,
        format: :date_time,
        description: "when the deployment was deployed",
        default: DateTime.from_unix!(0) |> DateTime.to_iso8601()
      }
    },
    required: ~w(subscription_sid)a
  })
end
