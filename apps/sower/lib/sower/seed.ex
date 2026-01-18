defmodule Sower.Seed do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.{Repo, Seed, SeedTag}
  alias Ecto.Multi

  @derive {Jason.Encoder, only: [:sid, :name, :seed_type, :artifact, :tags]}

  @derive {Phoenix.Param, key: :sid}

  @seed_types SowerClient.Seed.seed_types()

  schema "seeds" do
    field :sid, SowerClient.Sid
    field :org_id, Ecto.UUID

    field :name, :string
    field :seed_type, :string
    field :artifact, :string

    has_many :tags, SeedTag

    timestamps()
  end

  def create(attrs) do
    Multi.new()
    |> Multi.insert(
      :seed,
      changeset(
        %Seed{org_id: Sower.Repo.get_org_id(), sid: SowerClient.Sid.generate("seed")},
        attrs
      ),
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:name, :seed_type, :artifact, :org_id],
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
      {:ok, %{seed: seed}} -> {:ok, Repo.preload(seed, [:tags])}
      {:error, _} = error -> error
    end
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

  @doc """
  List seeds matching name, seed_type, and having ALL specified tags.

  Tags should be a list of maps with :key and :value fields.

  ## Options
    * `:limit` - Maximum number of seeds to return (default: 1)
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

    Repo.all(query)
    |> Repo.preload([:tags])
  end

  def list_matching(name, seed_type, tags, opts) when is_list(tags) do
    limit = Keyword.get(opts, :limit, 1)

    base_query =
      from(s in Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at, desc: s.id],
        limit: ^limit
      )

    query =
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

    query = from(s in query, as: :seed)

    Repo.all(query)
    |> Repo.preload([:tags])
  end

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

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type, :org_id, :artifact])
    |> validate_inclusion(:seed_type, @seed_types)
    |> validate_required([:name, :seed_type, :org_id, :artifact])
    |> unique_constraint([:name, :seed_type, :org_id, :artifact], error_key: :unique_seed)
  end
end
