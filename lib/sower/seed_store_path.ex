defmodule Sower.SeedStorePath do
  use Sower.Schema

  import Ecto.Changeset

  alias Sower.Repo

  schema "seeds_store_paths" do
    belongs_to :seed, Sower.Seed
    belongs_to :store_path, Sower.StorePath
    timestamps()
  end

  def insert!(seed, store_path) do
    %Sower.SeedStorePath{}
    |> changeset(%{seed_id: seed.id, store_path_id: store_path.id})
    |> Repo.insert!(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:seed_id, :store_path_id]
    )
  end

  defp changeset(seed_store_path, attrs) do
    seed_store_path
    |> cast(attrs, [:seed_id, :store_path_id])
    |> validate_required([:seed_id, :store_path_id])
  end
end
