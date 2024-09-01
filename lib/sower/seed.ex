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

  def submit(%{name: name, seed_type: seed_type, store_path: store_path}) do
    case Repo.get_by(Sower.Seed, name: name, seed_type: seed_type) do
      nil ->
        %Sower.Seed{}
        |> changeset(%{name: name, seed_type: seed_type, store_path: store_path})
        |> Repo.insert()

      seed ->
        SeedStorePath.insert!(seed, StorePath.submit!(store_path))

        {:ok, seed}
    end
  end

  # get by id and load store_paths
  def get_by_id!(id) do
    Repo.get(Sower.Seed, id) |> Repo.preload(:store_paths)
  end

  def list() do
    Repo.all(Sower.Seed)
  end

  def latest_by_name(name) do
    Repo.one(from s in Sower.Seed, where: s.name == ^name, order_by: [desc: s.updated_at])
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type])
    |> validate_inclusion(:seed_type, ["nixos", "home-manager", "nix-darwin"])
    |> put_assoc(:store_paths, parse_path(attrs))
    |> validate_required([:name, :seed_type])
  end

  defp parse_path(params) do
    case Map.get(params, :store_path) do
      nil ->
        false

      store_path ->
        [StorePath.submit!(store_path)]
    end
  end
end
