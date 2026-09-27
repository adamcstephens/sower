defmodule Sower.Orchestration.SeedPublisher do
  import Ecto.Query

  alias Sower.Orchestration.{Seed, SeedPublication, SeedTag}
  alias Sower.Repo

  @source_fields [:instance, :project, :job, :branch, :evaluation, :build, :revision, :order]

  def publish(source, attrs) when is_map(source) and is_map(attrs) do
    with :ok <- validate_source(source),
         :ok <- validate_descriptor(attrs) do
      Repo.transaction(fn -> publish_locked(source, attrs) end)
      |> case do
        {:ok, seed} -> {:ok, seed}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_source(source) do
    if Enum.all?(
         @source_fields -- [:order],
         &(is_binary(Map.get(source, &1)) and Map.get(source, &1) != "")
       ) and
         is_integer(source[:order]) and source.order >= 0 and
         source.branch != "HEAD" and not String.starts_with?(source.branch, "refs/pull/") do
      :ok
    else
      {:error, :invalid_source}
    end
  end

  defp validate_descriptor(%{name: name, seed_type: type, artifact: artifact} = attrs)
       when is_binary(name) and is_binary(type) and is_binary(artifact) do
    tags = Map.get(attrs, :tags, [])

    if is_list(tags) and
         Enum.all?(tags, fn
           %{key: key, value: value} ->
             is_binary(key) and is_binary(value) and key not in ["git_branch", "git_rev"]

           _ ->
             false
         end) do
      :ok
    else
      {:error, :invalid_tags}
    end
  end

  defp validate_descriptor(_), do: {:error, :invalid_descriptor}

  defp publish_locked(source, attrs) do
    org_id = Repo.get_org_id()
    key = [org_id, source.instance, source.project, source.job, attrs.name, attrs.seed_type]

    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      Enum.join(key, ":")
    ])

    identity = [
      org_id: org_id,
      instance: source.instance,
      project: source.project,
      job: source.job,
      evaluation: source.evaluation,
      build: source.build,
      seed_name: attrs.name,
      seed_type: attrs.seed_type
    ]

    case Repo.get_by(SeedPublication, identity) do
      nil -> register(source, attrs, org_id)
      publication -> replay(publication, source, attrs)
    end
  end

  defp replay(publication, source, attrs) do
    seed = Repo.get!(Seed, publication.seed_id) |> Repo.preload(:tags)

    requested_tags = normalize_tags(Map.get(attrs, :tags, []))

    if publication.branch == source.branch and publication.revision == source.revision and
         publication.source_order == source.order and seed.name == attrs.name and
         seed.seed_type == attrs.seed_type and seed.artifact == attrs.artifact and
         publication.tags == requested_tags do
      seed
    else
      Repo.rollback(:conflicting_publication)
    end
  end

  defp register(source, attrs, org_id) do
    previous =
      Repo.one(
        from(p in SeedPublication,
          where:
            p.instance == ^source.instance and p.project == ^source.project and
              p.job == ^source.job and p.branch == ^source.branch and
              p.seed_name == ^attrs.name and p.seed_type == ^attrs.seed_type,
          order_by: [desc: p.source_order],
          limit: 1
        )
      )

    changeset =
      Seed.publication_changeset(
        %Seed{org_id: org_id, sid: SowerClient.Sid.generate("seed")},
        Map.take(attrs, [:name, :seed_type, :artifact])
      )

    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    seed = Repo.get_by!(Seed, seed_type: attrs.seed_type, artifact: attrs.artifact)

    if seed.name != attrs.name, do: Repo.rollback(:conflicting_artifact)

    tags = Enum.map(Map.get(attrs, :tags, []), &Map.put(&1, :seed_id, seed.id))
    Repo.insert_all(SeedTag, tags, on_conflict: :nothing)

    publication =
      %SeedPublication{}
      |> SeedPublication.changeset(%{
        org_id: org_id,
        seed_id: seed.id,
        instance: source.instance,
        project: source.project,
        job: source.job,
        seed_name: attrs.name,
        seed_type: attrs.seed_type,
        branch: source.branch,
        evaluation: source.evaluation,
        build: source.build,
        revision: source.revision,
        source_order: source.order,
        tags: normalize_tags(Map.get(attrs, :tags, []))
      })
      |> Repo.insert!()

    if previous == nil or source.order > previous.source_order do
      %{"seed_id" => seed.id, "org_id" => org_id, "publication_id" => publication.id}
      |> Sower.Workers.RealtimeDeploy.new()
      |> Oban.insert!()
    end

    Repo.preload(seed, :tags)
  end

  defp normalize_tags(tags) do
    %{"pairs" => tags |> Enum.map(&[&1.key, &1.value]) |> Enum.sort()}
  end
end
