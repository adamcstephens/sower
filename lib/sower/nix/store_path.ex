defmodule Sower.Nix.StorePath do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:path, :path_digest]}
  @derive {Phoenix.Param, key: :path_digest}

  @path_regex ~r'/nix/store/(?<digest>[a-z0-9]{32})-[a-z0-9]+'

  schema "store_paths" do
    field :path, :string
    field :path_digest, Sower.Schema.Nix.StorePathDigest
    field :org_id, Ecto.UUID

    many_to_many :seeds, Sower.Seed, join_through: Sower.SeedStorePath

    many_to_many :deployments, Sower.Distribution.Deployment,
      join_through: Sower.Distribution.StorePathDeployment

    timestamps()
  end

  @doc false
  def changeset(store_path, attrs) do
    store_path
    |> cast(attrs, [:path])
    |> validate_required([:path])
    |> validate_format(:path, @path_regex, message: "must be a valid nix store path")
    |> unique_constraint(:path)
    |> unique_constraint(:path_digest)
    |> compute_digest()
  end

  def compute_digest(%Ecto.Changeset{} = changeset) do
    case get_field(changeset, :path_digest) do
      nil ->
        case get_field(changeset, :path) do
          nil ->
            changeset

          path ->
            %{"digest" => digest} = Regex.named_captures(@path_regex, path)

            changeset
            |> put_change(:path_digest, digest)
        end

      _ ->
        changeset
    end
  end
end
