defmodule Sower.Orchestration.Seed do
  use Sower.Schema
  use Flop.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.Repo

  alias Sower.Orchestration.{
    Deployment,
    GardenSeedGeneration,
    Seed,
    SeedDeployment,
    SeedTag,
    SeedPublication,
    Subscription,
    SubscriptionDeployment
  }

  alias Ecto.Multi

  @derive {Jason.Encoder, only: [:sid, :name, :seed_type, :artifact, :tags]}

  @derive {Phoenix.Param, key: :sid}

  @flop_options [
    filterable: [:name, :seed_type],
    sortable: [:name, :seed_type, :updated_at],
    default_limit: 20,
    default_order: %{
      order_by: [:updated_at],
      order_directions: [:desc]
    }
  ]

  @seed_types SowerClient.Seed.seed_types()

  schema "seeds" do
    field :sid, SowerClient.Sid
    field :org_id, Ecto.UUID

    field :name, :string
    field :seed_type, :string
    field :artifact, :string

    has_many :tags, SeedTag

    field :generation_number, :integer, virtual: true
    field :is_current, :boolean, virtual: true, default: false

    field :latest_deployment_state, Ecto.Enum,
      values: [:created, :dispatched, :acknowledged, :completed, :stale, :canceled],
      virtual: true

    field :latest_deployment_result, Ecto.Enum,
      values: [:success, :failure, :partial],
      virtual: true

    field :latest_deployment_sid, :string, virtual: true
    field :latest_deployment_at, :utc_datetime, virtual: true
    field :is_pending, :boolean, virtual: true, default: false

    timestamps()
  end

  @doc """
  Publishes a seed from a trusted integration. The caller supplies `source` with
  `:instance`, `:project`, `:job`, `:branch`, `:evaluation`, `:build`, `:revision`,
  and `:order`. `:order` is a monotonically increasing, globally comparable
  evaluation order (for example, evaluation creation time in microseconds),
  never callback arrival time or a commit hash. One evaluation/build may publish
  multiple seed names/types. The organization is taken from the repository
  context; descriptor tags cannot set `git_branch` or `git_rev`.

  Replays return the original seed without updating recency or scheduling work.
  An older accepted publication remains recorded for provenance, but cannot
  displace the newest publication of its branch stream.
  """
  def publish(source, attrs), do: Sower.Orchestration.SeedPublisher.publish(source, attrs)

  def publication_changeset(seed, attrs), do: changeset(seed, attrs)

  def create(attrs, opts \\ []) do
    replacements =
      if Keyword.get(opts, :rename, false) do
        [:name, :updated_at]
      else
        [:updated_at]
      end

    Multi.new()
    |> Multi.insert(
      :seed,
      changeset(
        %Seed{org_id: Sower.Repo.get_org_id(), sid: SowerClient.Sid.generate("seed")},
        attrs
      ),
      on_conflict: {:replace, replacements},
      conflict_target: [:seed_type, :artifact, :org_id],
      returning: true
    )
    |> Multi.run(:tags, fn repo, %{seed: seed} ->
      case attrs do
        %{tags: tags} when is_list(tags) ->
          tags =
            Enum.map(tags, fn tag_attrs ->
              tag_attrs
              |> Map.put(:seed_id, seed.id)
            end)

          repo.insert_all(SeedTag, tags, on_conflict: :nothing)

          {:ok, nil}

        _ ->
          {:ok, nil}
      end
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{seed: seed}} ->
        seed = Repo.preload(seed, [:tags])
        trigger_realtime_deploys(seed)
        {:ok, seed}

      {:error, _} = error ->
        error
    end
  end

  defp trigger_realtime_deploys(%Seed{} = seed) do
    %{"seed_id" => seed.id, "org_id" => seed.org_id}
    |> Sower.Workers.RealtimeDeploy.new()
    |> Oban.insert()
  end

  def create!(attrs, opts \\ []) do
    {:ok, seed} = create(attrs, opts)

    seed
  end

  def update(seed, attrs) do
    seed
    |> changeset(attrs)
    |> Repo.update()
  end

  def get_by_id!(id) do
    Repo.get!(Seed, id)
  end

  def get_by_id(id) do
    Repo.get(Seed, id)
  end

  def get!(name, seed_type) do
    Repo.get_by!(Seed, name: name, seed_type: seed_type)
  end

  def get(name, seed_type) do
    query =
      from s in Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at]

    Repo.all(query)
    |> Repo.preload([:tags])
  end

  @doc """
  Get a seed from a SowerClient.Seed struct.
  Returns `{:ok, seed}` or `nil` if not found.
  """
  def get_by_request(%SowerClient.Seed{name: name, seed_type: seed_type}) do
    case get(name, seed_type) do
      nil -> nil
      seed -> {:ok, seed}
    end
  end

  def get_sid(sid) do
    Repo.get_by(Seed, sid: sid) |> Repo.preload([:tags])
  end

  def get_sid!(sid) do
    Repo.get_by!(Seed, sid: sid) |> Repo.preload([:tags])
  end

  @doc """
  Gets a seed by its artifact (Nix store path).

  Returns the seed or nil if not found.
  """
  def get_by_artifact(artifact) do
    Repo.get_by(Seed, artifact: artifact) |> Repo.preload([:tags])
  end

  def list() do
    query = from s in Seed, order_by: [desc: s.updated_at]

    Repo.all(query)
    |> Repo.preload([:tags])
  end

  def list_flop(params \\ %{}) do
    case Flop.validate_and_run(Seed, params, for: Seed) do
      {:ok, {seeds, meta}} ->
        {:ok, {Repo.preload(seeds, [:tags]), meta}}

      {:error, meta} ->
        {:error, meta}
    end
  end

  @doc """
  List matching seeds enriched with generation and deployment info for a subscription.

  Returns seeds matching the subscription's name/type/rules, enriched with:
  - generation_number and is_current from garden_seed_generations
  - latest deployment state/result from this subscription's deployments
  - is_pending flag (no successful deployment, or seed updated after last deployment)

  Paginated via Flop with a default limit of 10.
  """
  def list_matching_enriched(%Subscription{} = subscription, garden_id, params) do
    tags =
      Enum.map(subscription.rules || [], fn rule ->
        %{key: rule.key, value: rule.value}
      end)

    base_query =
      from(s in Seed,
        as: :seed,
        where: s.name == ^subscription.seed_name and s.seed_type == ^subscription.seed_type
      )

    base_query =
      Enum.reduce(tags, base_query, fn %{key: key, value: value}, query ->
        from(s in query,
          where:
            exists(
              from(st in SeedTag,
                where: st.seed_id == parent_as(:seed).id,
                where: st.key == ^key and st.value == ^value
              )
            )
        )
      end)

    gen_query =
      from(g in GardenSeedGeneration,
        where: g.garden_id == ^garden_id and g.seed_id == parent_as(:seed).id,
        select: %{generation_number: g.generation_number, is_current: g.is_current},
        limit: 1
      )

    deploy_query =
      from(d in Deployment,
        join: sd in SeedDeployment,
        on: sd.deployment_id == d.id,
        join: sub_d in SubscriptionDeployment,
        on: sub_d.deployment_id == d.id,
        where: sd.seed_id == parent_as(:seed).id,
        where: sub_d.subscription_id == ^subscription.id,
        order_by: [desc: d.inserted_at],
        limit: 1,
        select: %{sid: d.sid, state: d.state, result: d.result, deployed_at: d.deployed_at}
      )

    last_successful_deploy_query =
      from(d in Deployment,
        join: sub_d in SubscriptionDeployment,
        on: sub_d.deployment_id == d.id,
        where: sub_d.subscription_id == ^subscription.id,
        where: d.result == :success and not is_nil(d.deployed_at),
        order_by: [desc: d.deployed_at],
        limit: 1,
        select: d.deployed_at
      )

    last_successful_at = Repo.one(last_successful_deploy_query, skip_org_id: true)

    query =
      from(s in base_query,
        left_lateral_join: g in subquery(gen_query),
        on: true,
        left_lateral_join: ld in subquery(deploy_query),
        on: true,
        select_merge: %{
          generation_number: g.generation_number,
          is_current: coalesce(g.is_current, false),
          latest_deployment_sid: ld.sid,
          latest_deployment_state: ld.state,
          latest_deployment_result: ld.result,
          latest_deployment_at: ld.deployed_at,
          is_pending: false
        }
      )

    case Flop.validate_and_run(query, params, for: Seed, default_limit: 10) do
      {:ok, {seeds, meta}} ->
        seeds =
          seeds
          |> Repo.preload([:tags])
          |> mark_newest_pending(last_successful_at)

        {:ok, {seeds, meta}}

      {:error, meta} ->
        {:error, meta}
    end
  end

  defp mark_newest_pending(seeds, nil), do: seeds

  defp mark_newest_pending(seeds, last_successful_at) do
    newest =
      seeds
      |> Enum.filter(fn seed -> DateTime.compare(seed.updated_at, last_successful_at) == :gt end)
      |> Enum.max_by(& &1.updated_at, DateTime, fn -> nil end)

    case newest do
      nil ->
        seeds

      %Seed{id: pending_id} ->
        Enum.map(seeds, fn seed ->
          if seed.id == pending_id, do: %{seed | is_pending: true}, else: seed
        end)
    end
  end

  @doc """
  List seeds matching name, seed_type, and having ALL specified tags.

  Tags should be a list of maps with :key and :value fields.

  ## Options
    * `:limit` - Maximum number of seeds to return (default: 1)
    * `:sid` - Restrict matching to the seed with this sid
  """
  def list_matching(name, seed_type, tags, opts \\ [])

  def list_matching(name, seed_type, [], opts) do
    limit = Keyword.get(opts, :limit, 1)

    query =
      from(s in Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at, desc: s.id],
        limit: ^limit
      )
      |> filter_sid(Keyword.get(opts, :sid))

    Repo.all(query)
    |> Repo.preload([:tags])
  end

  def list_matching(name, seed_type, tags, opts) when is_list(tags) do
    limit = Keyword.get(opts, :limit, 1)

    {provenance, ordinary} =
      Enum.split_with(tags, &(&1.key in ["git_branch", "git_rev"]))

    base =
      from(s in Seed,
        as: :seed,
        where: s.name == ^name and s.seed_type == ^seed_type
      )
      |> filter_sid(Keyword.get(opts, :sid))

    ordinary_query =
      Enum.reduce(ordinary, base, fn %{key: key, value: value}, query ->
        from(s in query,
          where:
            exists(
              from(st in SeedTag,
                where: st.seed_id == parent_as(:seed).id,
                where: st.key == ^key and st.value == ^value
              )
            )
        )
      end)

    query =
      case provenance do
        [] ->
          from(s in ordinary_query, order_by: [desc: s.updated_at, desc: s.id], limit: ^limit)

        _ ->
          branch =
            Enum.find_value(provenance, fn tag -> if tag.key == "git_branch", do: tag.value end)

          revision =
            Enum.find_value(provenance, fn tag -> if tag.key == "git_rev", do: tag.value end)

          publications =
            from(p in SeedPublication,
              where: p.seed_id == parent_as(:seed).id,
              select: %{source_order: max(p.source_order)}
            )

          publications =
            if branch, do: from(p in publications, where: p.branch == ^branch), else: publications

          publications =
            if revision,
              do: from(p in publications, where: p.revision == ^revision),
              else: publications

          publications =
            Enum.reduce(ordinary, publications, fn %{key: key, value: value}, query ->
              from(p in query,
                where:
                  fragment(
                    "EXISTS (SELECT 1 FROM jsonb_array_elements(?->'pairs') AS pair WHERE pair->>0 = ? AND pair->>1 = ?)",
                    p.tags,
                    ^key,
                    ^value
                  )
              )
            end)

          local_tags =
            Enum.reduce(provenance, ordinary_query, fn %{key: key, value: value}, query ->
              from(s in query,
                where:
                  exists(
                    from(st in SeedTag,
                      where: st.seed_id == parent_as(:seed).id,
                      where: st.key == ^key and st.value == ^value
                    )
                  )
              )
            end)

          local_ids =
            from(s in local_tags,
              where:
                not exists(from(p in SeedPublication, where: p.seed_id == parent_as(:seed).id)),
              select: s.id
            )

          from(s in base,
            left_lateral_join: publication in subquery(publications),
            on: true,
            where: not is_nil(publication.source_order) or s.id in subquery(local_ids),
            order_by: [
              desc:
                coalesce(
                  publication.source_order,
                  fragment("extract(epoch from ?) * 1000000", s.updated_at)
                ),
              desc: s.id
            ],
            limit: ^limit
          )
      end

    Repo.all(query) |> Repo.preload(:tags)
  end

  defp filter_sid(query, nil), do: query
  defp filter_sid(query, sid), do: from(s in query, where: s.sid == ^sid)

  def latest(name, seed_type) do
    Repo.one(
      from s in Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at, desc: s.id],
        limit: 1
    )
    |> Repo.preload([:tags])
  end

  @doc """
  Get the latest seed matching name, seed_type, and having ALL specified tags.

  Tags should be a list of maps with :key and :value fields.
  Returns nil if no seed matches all tags.
  """
  def latest(name, seed_type, tags) when is_list(tags) do
    case list_matching(name, seed_type, tags, limit: 1) do
      [seed] -> seed
      [] -> nil
    end
  end

  def latest_artifact(%__MODULE__{id: id}) do
    Repo.one(
      from s in Seed,
        where: s.id == ^id,
        order_by: [desc: s.updated_at]
    )
    |> Repo.preload([:tags])
  end

  def latest_artifact_by_sid(sid) do
    Repo.one(
      from s in Seed,
        where: s.sid == ^sid,
        order_by: [desc: s.updated_at]
    )
    |> Repo.preload([:tags])
  end

  @doc """
  Finds an existing seed by artifact path, or registers a new one from garden-reported data.

  When a garden reports a generation that doesn't match any known seed, this function
  auto-registers it with the `garden_source` tag set to the garden's SID.

  ## Parameters
    - `garden` - The Garden struct reporting the generation
    - `generation` - The GardenSeedGeneration with path, link, etc.
    - `profile` - The GardenSeedProfile containing profile_path and tags

  ## Returns
    - `{:ok, seed}` on success (existing or newly created)
    - `{:error, changeset}` on validation failure
  """
  def find_or_register(
        %Sower.Orchestration.Garden{} = garden,
        %SowerClient.Orchestration.GardenSeedGeneration{} = generation,
        %SowerClient.Orchestration.GardenSeedProfile{} = profile
      ) do
    case get_by_artifact(generation.path) do
      nil ->
        register(garden, generation, profile)

      seed ->
        {:ok, seed}
    end
  end

  defp register(garden, generation, profile) do
    {name, path_tags} = extract_info_from_store_path(generation.path)
    seed_type = seed_type_from_profile_path(profile.profile_path)

    # Build tags: garden_source + any profile tags
    tags =
      path_tags ++
        [%{key: "garden_source", value: garden.sid}] ++
        Enum.map(profile.tags || [], fn {k, v} -> %{key: to_string(k), value: to_string(v)} end)

    name =
      if seed_type == "home-manager" do
        case Enum.find_value(profile.tags, fn
               {"user", user_name} -> user_name
               _ -> nil
             end) do
          nil -> name
          user_name -> "#{user_name}@#{garden.name}"
        end
      else
        name
      end

    create(%{
      name: name,
      seed_type: seed_type,
      artifact: generation.path,
      tags: tags
    })
  end

  @doc """
  Extracts the derivation name and tags from a Nix store path.

  The Nix store path format is `/nix/store/{hash}-{name}` where the hash
  is 32 characters. This function extracts the name portion after the first hyphen.

  ## Examples

      iex> Sower.Orchestration.Seed.extract_info_from_store_path("/nix/store/abc123-nixos-system-myhost-25.11")
      {"myhost", [%{key: "nixos_version", value: "25.05"}]}

      iex> Sower.Orchestration.Seed.extract_info_from_store_path("/nix/store/xyz789-home-manager-generation")
      {"home-manager-generation", []}
  """
  def extract_info_from_store_path(path) do
    basename = Path.basename(path)

    case String.split(basename, "-", parts: 2) do
      [_hash, name] ->
        case String.split(name, "-") do
          ["nixos", "system", name, nixos_version] ->
            {name, [%{key: "nixos_version", value: nixos_version}]}

          _ ->
            {name, []}
        end

      [name] ->
        {name, []}
    end
  end

  @doc """
  Determines the seed type from a Nix profile path.

  ## Examples

      iex> Sower.Orchestration.Seed.seed_type_from_profile_path("/nix/var/nix/profiles/system")
      "nixos"

      iex> Sower.Orchestration.Seed.seed_type_from_profile_path("/home/user/.local/state/nix/profiles/home-manager")
      "home-manager"

      iex> Sower.Orchestration.Seed.seed_type_from_profile_path("/run/current-system/sw")
      "nixos"
  """
  def seed_type_from_profile_path(profile_path) do
    cond do
      String.contains?(profile_path, "home-manager") -> "home-manager"
      String.contains?(profile_path, "/nix/var/nix/profiles/system") -> "nixos"
      String.contains?(profile_path, "nix-darwin") -> "nix-darwin"
      true -> "nixos"
    end
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type, :org_id, :artifact])
    |> validate_inclusion(:seed_type, @seed_types)
    |> validate_required([:name, :seed_type, :org_id, :artifact])
    |> unique_constraint([:name, :seed_type, :org_id, :artifact], error_key: :unique_seed)
  end
end
