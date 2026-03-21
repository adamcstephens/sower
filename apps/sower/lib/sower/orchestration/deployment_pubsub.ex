defmodule Sower.Orchestration.DeploymentPubSub do
  @moduledoc """
  PubSub broadcasting for deployment events.
  """

  alias Sower.Orchestration.Deployment
  require Logger

  @doc """
  Broadcasts when a deployment is created or updated.

  Broadcasts to multiple topics:
  - "deployments" - Global topic for all deployments
  - "deployment:<deployment_sid>" - Per-deployment topic
  - "deployments:garden:<garden_sid>" - Per-garden topic
  - "deployments:subscription:<subscription_sid>" - Per-subscription topics
  """
  def broadcast_deployment_change(%Deployment{} = deployment, event \\ :updated) do
    deployment = Sower.Repo.preload(deployment, [:garden, :subscriptions])

    broadcast("deployments", {:deployment, event, deployment})
    broadcast("deployment:#{deployment.sid}", {:deployment, event, deployment})

    if deployment.garden do
      broadcast(
        "deployments:garden:#{deployment.garden.sid}",
        {:deployment, event, deployment}
      )

      # Deprecated: kept for 0.7.0 LiveView backward compatibility
      broadcast(
        "deployments:agent:#{deployment.garden.sid}",
        {:deployment, event, deployment}
      )
    end

    Enum.each(deployment.subscriptions, fn subscription ->
      broadcast(
        "deployments:subscription:#{subscription.sid}",
        {:deployment, event, deployment}
      )
    end)

    {:ok, deployment}
  end

  defp broadcast(topic, message) do
    case Phoenix.PubSub.broadcast(Sower.PubSub, topic, message) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to broadcast deployment change to #{topic}: #{inspect(reason)}")
        :ok
    end
  end
end
