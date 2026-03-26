defmodule Sower.Orchestration.Seed do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.Repo
  alias Sower.Orchestration.{Seed, SeedTag}
  alias Ecto.Multi

  @derive {Jason.Encoder, only: [:sid, :name, :seed_type, :artifact, :tags]}

  @derive {Phoenix.Param, key: :sid}

  @derive {
    Flop.Schema,
    filterable: [:name, :seed_type],
    sortable: [:name, :seed_type, :updated_at],
    default_limit: 20,
    default_order: %{
      order_by: [:updated_at],
      order_directions: [:desc]
    }
  }

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
      {:ok, %{seed: seed}} -> {:ok, Repo.preload(seed, [:tags])}
      {:error, _} = error -> error
    end
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
