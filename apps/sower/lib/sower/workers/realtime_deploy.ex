defmodule Sower.Workers.RealtimeDeploy do
  use Oban.Worker, queue: :default, max_attempts: 3

  alias Sower.Orchestration.{Seed, Subscription}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"seed_id" => seed_id, "org_id" => org_id}}) do
    Sower.Repo.put_org_id(org_id)

    seed = seed_id |> Seed.get_by_id!() |> Sower.Repo.preload([:tags])
    subscriptions = Subscription.find_realtime_subscriptions(seed)

    subscriptions
    |> Enum.map(fn sub ->
      Sower.Workers.DeploySubscription.new(%{"subscription_sid" => sub.sid, "org_id" => org_id})
    end)
    |> Oban.insert_all()

    :ok
  end
end
