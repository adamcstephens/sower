defmodule Sower.Seed do
  use Sower.Schema
  import Ecto.Changeset
  alias Sower.Repo

  @derive {Jason.Encoder, only: [:id, :name, :seed_type]}

  schema "seeds" do
    field :name, :string
    field :seed_type, :string

    many_to_many :store_paths, Sower.StorePath, join_through: "seeds_store_paths"

    timestamps()
  end

  def submit(%{name: name, seed_type: seed_type, store_path: store_path}) do
    case Repo.get_by(Sower.Seed, name: name, seed_type: seed_type) do
      nil ->
        case %Sower.Seed{} |> changeset(%{name: name, seed_type: seed_type}) |> Repo.insert() do
          {:ok, seed} -> {:ok, seed}
          {:error, err} -> {:error, err}
        end

      seed ->
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

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type])
    |> validate_inclusion(:seed_type, ["nixos", "home-manager", "nix-darwin"])
    # |> put_assoc(:store_paths, parse_path(attrs))
    |> validate_required([:name, :seed_type])
  end

  defp parse_path(params) do
    dbg(params)

    case Map.get("store_path") do
      nil ->
        false

      store_path ->
        Repo.get_by(Sower.StorePath, path: store_path) ||
          Repo.insert!(%Sower.StorePath{path: store_path})
    end
  end
end
