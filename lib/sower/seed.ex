defmodule Sower.Seed do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.{Repo, Seed, SeedStorePath, StorePath}

  @derive {Jason.Encoder, only: [:id, :name, :seed_type]}

  schema "seeds" do
    field :name, :string
    field :seed_type, :string
    field :org_id, Ecto.UUID

    many_to_many :store_paths, StorePath, join_through: Sower.SeedStorePath

    timestamps()
  end

  def create(attrs) do
    %Sower.Seed{
      org_id: Sower.Repo.get_org_id()
    }
    |> changeset(attrs)
    |> Repo.insert()
  end

  def submit(%Seed{} = seed, path) do
    store_path = StorePath.submit!(path)

    SeedStorePath.submit!(seed, store_path)

    {:ok, _} = updated_at_now(seed)

    {:ok, store_path}
  end

  def submit(seed_id, path) do
    seed = get_by_id!(seed_id)
    submit(seed, path)
  end

  def update(seed, attrs) do
    seed
    |> changeset(attrs)
    |> Repo.update()
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

    case Repo.one(query) do
      nil ->
        nil

      store_path ->
        store_path |> Repo.preload(:store_path) |> Map.get(:store_path)
    end
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type, :org_id])
    |> validate_inclusion(:seed_type, ["nixos", "home-manager", "nix-darwin"])
    |> validate_required([:name, :seed_type, :org_id])
    |> unique_constraint([:name, :seed_type, :org_id], error_key: :unique_seed)
  end

  defp updated_at_now(seed) do
    seed
    |> change()
    |> put_change(:updated_at, NaiveDateTime.local_now())
    |> Repo.update()
  end
end
