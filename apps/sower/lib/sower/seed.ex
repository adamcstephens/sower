defmodule Sower.Seed do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.{Nix, Repo, Seed}

  @derive {Jason.Encoder, only: [:sid, :name, :seed_type]}

  @derive {Phoenix.Param, key: :sid}

  @seed_types SowerClient.Schemas.Seed.seed_types()

  schema "seeds" do
    field :sid, SowerClient.Schemas.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    field :name, :string
    field :seed_type, :string
    field :store_path, :string

    timestamps()
  end

  def create(attrs) do
    %Seed{
      org_id: Sower.Repo.get_org_id()
    }
    |> changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:name, :seed_type, :store_path, :org_id],
      returning: true
    )
  end

  def update(seed, attrs) do
    seed
    |> changeset(attrs)
    |> Repo.update()
  end

  def get_by_id!(id) do
    Repo.get!(Seed, id)
  end

  def get_by_id(id) do
    Repo.get(Seed, id)
  end

  def get!(name, seed_type) do
    Repo.get_by!(Seed, name: name, seed_type: seed_type)
  end

  def get(name, seed_type) do
    Repo.get_by(Seed, name: name, seed_type: seed_type)
  end

  def get_sid!(sid) do
    Repo.get_by!(Seed, sid: sid)
  end

  def list() do
    Repo.all(Seed)
  end

  def latest(name, seed_type) do
    Repo.one(
      from s in Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at]
    )
  end

  def latest_store_path(%__MODULE__{id: id}) do
    Repo.one(
      from s in Seed,
        where: s.id == ^id,
        order_by: [desc: s.updated_at]
    )
  end

  def latest_store_path_by_sid(sid) do
    Repo.one(
      from s in Seed,
        where: s.sid == ^sid,
        order_by: [desc: s.updated_at]
    )
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type, :org_id, :store_path])
    |> validate_inclusion(:seed_type, @seed_types)
    |> validate_required([:name, :seed_type, :org_id, :store_path])
    |> unique_constraint([:name, :seed_type, :org_id, :store_path], error_key: :unique_seed)
  end

  defp updated_at_now(seed) do
    seed
    |> change()
    |> put_change(:updated_at, NaiveDateTime.local_now())
    |> Repo.update()
  end
end
