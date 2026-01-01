defmodule Sower.Forge.Connection do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Phoenix.Param, key: :sid}

  schema "forges" do
    field :sid, SowerClient.Sid, autogenerate: true
    field :name, :string
    field :type, Ecto.Enum, values: [:forgejo]
    field :url, :string
    field :client_id, Sower.Vault.Binary
    field :client_secret, Sower.Vault.Binary
    field :org_id, Ecto.UUID

    has_many :repositories, Sower.Forge.Repository, foreign_key: :forge_id

    timestamps()
  end

  @doc false
  def changeset(connection, attrs) do
    connection
    |> cast(attrs, [:name, :url, :type, :client_id, :client_secret, :org_id])
    |> validate_required([:name, :url, :type, :client_id, :client_secret])
  end
end
