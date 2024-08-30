defmodule Sower.StorePath do
  use Sower.Schema
  import Ecto.Changeset

  schema "store_paths" do
    field :path, :string

    many_to_many :seeds, Sower.Seed, join_through: "seeds_store_paths"

    timestamps()
  end

  def changeset(store_path, attrs) do
    store_path
    |> cast(attrs, [:path])
    |> validate_required([:path])
    |> validate_format(:path, ~r'/nix/store/[a-z0-9]{32}-[a-z0-9]+',
      message: "must be a valid nix store path"
    )
  end

  def submit(path, seed_id) do
    %Sower.StorePath{}
    |> changeset(%{path: path, seed_id: seed_id})
    |> Sower.Repo.insert()
  end
end
