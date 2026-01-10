defmodule SowerClient.Orchestration.SubscriptionSync do
  use SowerClient.Schema
  use SowerClient.ChannelMessage, event: "subscriptions:sync"

  OpenApiSpex.schema(%{
    title: "SubscriptionSync",
    type: :object,
    properties: %{
      subscriptions: %Schema{
        type: :array,
        items: SowerClient.Orchestration.Subscription,
        description: "List of subscriptions to sync"
      }
    },
    required: [:subscriptions]
  })
end
