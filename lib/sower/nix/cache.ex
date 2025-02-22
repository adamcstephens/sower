defmodule Sower.Nix.Cache do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Phoenix.Param, key: :sid}

  schema "nix_caches" do
    field :sid, Sower.Schema.Sid, autogenerate: true
    field :public_key, :string
    field :url, :string
    field :org_id, Ecto.UUID

    timestamps()
  end

  @doc false
  def changeset(cache, attrs) do
    cache
    |> cast(attrs, [:url, :public_key])
    |> validate_required([:url, :public_key])
    |> unique_constraint([:url])
  end
end
