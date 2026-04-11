defmodule Sower.Workers.DeploySubscription do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Sower.Orchestration.{Deployment, Subscription}

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"subscription_sid" => sid, "org_id" => org_id}}) do
    Sower.Repo.put_org_id(org_id)
    run(sid)
  end

  def run(sid, deploy_fun \\ &Deployment.deploy_subscription/2) do
    now = DateTime.utc_now()

    case Subscription.get_subscription_sid(sid) do
      nil ->
        Logger.warning(msg: "Subscription not found for deploy", subscription_sid: sid)
        :ok

      sub ->
        if Subscription.within_window?(sub, now) do
          deploy(sub, deploy_fun)
        else
          :ok
        end
    end
  end

  defp deploy(%Subscription{} = sub, deploy_fun) do
    sub = Sower.Repo.preload(sub, :garden)

    case deploy_fun.(sub, actor_sid: sub.garden.sid, event_reason: :realtime_triggered) do
      {:ok, request_id, _pid} ->
        Logger.info(
          msg: "Realtime deploy triggered",
          subscription_sid: sub.sid,
          request_id: request_id
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          msg: "Realtime deploy failed",
          subscription_sid: sub.sid,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end
end
