defmodule Sower.Client do
  use Sower.Schema
  # import Ecto.Changeset
  alias Sower.Repo

  @derive {Jason.Encoder, only: [:sid, :name]}
  @derive {Phoenix.Param, key: :sid}

  schema "clients" do
    field :sid, Sower.Schema.Sid, autogenerate: true
    field :name, :string
    field :org_id, Ecto.UUID

    timestamps()
  end

  def list() do
    Repo.all(Sower.Client)
  end

  def get!(id) do
    Repo.get!(Sower.Client, id)
  end

  def get_sid!(sid) do
    Repo.get_by!(Sower.Client, sid: sid)
  end

  # defp changeset(seed, attrs) do
  #   seed
  #   |> cast(attrs, [:name])
  #   |> validate_required([:name, :seed_type])
  # end
end
