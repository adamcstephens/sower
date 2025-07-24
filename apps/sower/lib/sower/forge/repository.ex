defmodule Sower.Forge.Repository do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Phoenix.Param, key: :sid}

  schema "repositories" do
    field :sid, SowerClient.Schemas.Sid, autogenerate: true
    field :owner, :string
    field :repo, :string
    field :url, :string
    field :webhook_id, :string
    field :webhook_secret, Sower.Vault.Binary
    field :org_id, Ecto.UUID

    belongs_to :forge, Sower.Forge.Connection, foreign_key: :forge_id

    timestamps()
  end

  @doc false
  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:owner, :repo, :url, :forge_id, :webhook_id, :webhook_secret])
    |> validate_required([:owner, :repo, :forge_id, :url, :webhook_secret])
    |> unique_constraint([:owner, :repo, :forge_id])
  end
end
