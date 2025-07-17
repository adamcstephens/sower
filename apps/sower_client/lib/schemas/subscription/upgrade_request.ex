defmodule SowerClient.Schemas.Subscription.UpgradeRequest do
  use SowerClient.Schema

  OpenApiSpex.schema(%{
    title: "SubscriptionUpgradeRequest",
    type: :object,
    properties: %{
      subscription_sid: %Schema{
        type: :string,
        description: "subscription sid allocated by Sower",
        readOnly: true
      }
    },
    required: ~w(subscription_sid)a
  })
end
