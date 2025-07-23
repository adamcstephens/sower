defmodule Sower.Orchestration.SubscriptionDeployment do
  use Sower.Schema
  import Ecto.Changeset

  schema "subscriptions_deployments" do
    field :subscription_id, :id
    field :deployment_id, :id

    timestamps()
  end

  @doc false
  def changeset(subscription_deployment, attrs) do
    subscription_deployment
    |> cast(attrs, [])
    |> validate_required([:subscription_id, :deployment_id])
  end
end
