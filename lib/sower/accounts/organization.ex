defmodule Sower.Accounts.Organization do
  use Sower.Schema

  import Ecto.Changeset

  alias Sower.Accounts.Organization
  alias Sower.Repo

  @primary_key {:org_id, UUIDv7, autogenerate: true}
  schema "organizations" do
    field :name
    timestamps()
  end

  def create(attrs \\ %{}) do
    %Organization{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name])
    |> validate_required([:name])
  end

  def list() do
    Sower.Repo.all(Organization, skip_org_id: true)
  end
end
