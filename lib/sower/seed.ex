defmodule Sower.Seed do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.{Repo, SeedStorePath, StorePath}

  @derive {Jason.Encoder, only: [:id, :name, :seed_type]}

  schema "seeds" do
    field :name, :string
    field :seed_type, :string

    many_to_many :store_paths, StorePath, join_through: Sower.SeedStorePath

    timestamps()
  end

  def new(attrs) do
    %Sower.Seed{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def submit(seed_id, path) do
    store_path = StorePath.submit!(path)

    seed = get_by_id!(seed_id)

    SeedStorePath.submit!(seed, store_path)

    {:ok, seed}
  end

  def get_by_id!(id) do
    Repo.get!(Sower.Seed, id)
  end

  def get_by_id(id) do
    Repo.get(Sower.Seed, id)
  end

  def get!(name, seed_type) do
    Repo.get_by!(Sower.Seed, name: name, seed_type: seed_type)
  end

  def get(name, seed_type) do
    Repo.get_by(Sower.Seed, name: name, seed_type: seed_type)
  end

  def list() do
    Repo.all(Sower.Seed)
  end

  def latest(name, seed_type) do
    Repo.one(
      from s in Sower.Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at]
    )
  end

  def latest_store_path_by_id(id) do
    seed = Sower.Seed.get_by_id!(id)

    query =
      from sp in Sower.SeedStorePath,
        where: sp.seed_id == ^seed.id,
        order_by: [desc: sp.updated_at],
        limit: 1

    Repo.one(query) |> Repo.preload(:store_path) |> Map.get(:store_path)
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type])
    |> validate_inclusion(:seed_type, ["nixos", "home-manager", "nix-darwin"])
    |> validate_required([:name, :seed_type])
    |> unique_constraint([:name, :seed_type], error_key: :unique_seed)
  end
end
