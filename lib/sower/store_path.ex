defmodule Sower.StorePath do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :path]}

  schema "store_paths" do
    field :path, :string

    many_to_many :seeds, Sower.Seed, join_through: Sower.SeedStorePath

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

  def submit!(path) do
    %Sower.StorePath{}
    |> changeset(%{path: path})
    |> Sower.Repo.insert!(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:path],
      returning: true
    )
  end

  def get_by_path!(path) do
    Sower.Repo.get_by!(Sower.StorePath, path: path)
  end
end
