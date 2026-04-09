defmodule Sower.Orchestration.Workflows.RealtimeDeploy do
  use Durable

  alias Sower.Orchestration.{Deployment, Subscription}

  require Logger

  workflow "realtime_deploy" do
    step(:find_subscriptions, fn input ->
      seed = Sower.Orchestration.Seed.get_by_id!(input["seed_id"])
      subscriptions = Subscription.find_realtime_subscriptions(seed)
      {:ok, %{subscription_sids: Enum.map(subscriptions, & &1.sid)}}
    end)

    step(:deploy, [retry: [max_attempts: 3, backoff: :exponential]], fn data ->
      now = DateTime.utc_now()

      results =
        data.subscription_sids
        |> Enum.map(&Subscription.get_subscription_sid/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.filter(&Subscription.within_window?(&1, now))
        |> Enum.map(fn sub ->
          case Deployment.deploy_subscription(sub) do
            {:ok, request_id, _pid} ->
              Logger.info(
                msg: "Realtime deploy triggered",
                subscription_sid: sub.sid,
                request_id: request_id
              )

              {:ok, sub.sid}

            {:error, reason} ->
              Logger.warning(
                msg: "Realtime deploy failed",
                subscription_sid: sub.sid,
                error: inspect(reason)
              )

              {:error, sub.sid, reason}
          end
        end)

      {:ok, Map.put(data, :results, results)}
    end)
  end
end
