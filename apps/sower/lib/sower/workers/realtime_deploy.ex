defmodule Sower.Workers.RealtimeDeploy do
  use Oban.Worker, queue: :default, max_attempts: 3
  import Ecto.Query, only: [from: 2]

  alias Sower.Orchestration.{Seed, SeedPublication, SeedPublicationDispatch, Subscription}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"publication_id" => publication_id, "org_id" => org_id}}) do
    Sower.Repo.put_org_id(org_id)
    publication = Sower.Repo.get!(SeedPublication, publication_id)
    seed = publication.seed_id |> Seed.get_by_id!() |> Sower.Repo.preload(:tags)

    current =
      Sower.Repo.exists?(
        from(p in SeedPublication,
          where:
            p.instance == ^publication.instance and p.project == ^publication.project and
              p.job == ^publication.job and p.branch == ^publication.branch and
              p.seed_name == ^publication.seed_name and p.seed_type == ^publication.seed_type and
              p.source_order > ^publication.source_order
        )
      )

    unless current do
      tags =
        Enum.map(publication.tags["pairs"], fn [key, value] ->
          %{key: key, value: value}
        end) ++
          [
            %{key: "git_branch", value: publication.branch},
            %{key: "git_rev", value: publication.revision}
          ]

      subscriptions = Subscription.find_realtime_subscriptions(%{seed | tags: tags})

      {:ok, _} =
        Sower.Repo.transaction(fn ->
          Enum.each(subscriptions, fn sub ->
            {inserted, _} =
              Sower.Repo.insert_all(
                SeedPublicationDispatch,
                [%{org_id: org_id, publication_id: publication.id, subscription_id: sub.id}],
                on_conflict: :nothing,
                conflict_target: [:publication_id, :subscription_id]
              )

            if inserted == 1 do
              %{"subscription_sid" => sub.sid, "org_id" => org_id}
              |> Sower.Workers.DeploySubscription.new()
              |> Oban.insert!()
            end
          end)
        end)
    end

    :ok
  end

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
