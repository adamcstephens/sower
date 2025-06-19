defmodule Sower.SeedStorePath do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Sower.Repo

  schema "seeds_store_paths" do
    field :org_id, Ecto.UUID
    belongs_to :seed, Sower.Seed
    belongs_to :store_path, Sower.Nix.StorePath
    timestamps()
  end

  def find!(seed_id, store_path_id) do
    query =
      from ssp in Sower.SeedStorePath,
        where: ssp.seed_id == ^seed_id,
        where: ssp.store_path_id == ^store_path_id

    Repo.one!(query)
  end

  def submit!(seed, store_path) do
    %Sower.SeedStorePath{
      org_id: Sower.Repo.get_org_id()
    }
    |> changeset(%{seed_id: seed.id, store_path_id: store_path.id})
    |> Repo.insert!(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:seed_id, :store_path_id, :org_id]
    )
  end

  defp changeset(seed_store_path, attrs) do
    seed_store_path
    |> cast(attrs, [:seed_id, :store_path_id])
    |> validate_required([:seed_id, :store_path_id])
  end
end
