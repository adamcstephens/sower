defmodule Sower.Seed do
  use Sower.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Sower.{Repo, Seed, SeedTag}
  alias Ecto.Multi

  @derive {Jason.Encoder, only: [:sid, :name, :seed_type, :artifact]}

  @derive {Phoenix.Param, key: :sid}

  @seed_types SowerClient.Schemas.Seed.seed_types()

  schema "seeds" do
    field :sid, SowerClient.Schemas.Sid, autogenerate: true
    field :org_id, Ecto.UUID

    field :name, :string
    field :seed_type, :string
    field :artifact, :string

    has_many :tags, SeedTag

    timestamps()
  end

  def create(attrs) do
    Multi.new()
    |> Multi.insert(:seed, changeset(%Seed{org_id: Sower.Repo.get_org_id()}, attrs),
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:name, :seed_type, :artifact, :org_id],
      returning: true
    )
    |> Multi.run(:tags, fn repo, %{seed: seed} ->
      case attrs do
        %{tags: tags} when is_list(tags) ->
          tags =
            Enum.map(tags, fn tag_attrs ->
              tag_attrs
              |> Map.put(:seed_id, seed.id)
            end)

          repo.insert_all(SeedTag, tags, on_conflict: :nothing)

          {:ok, nil}

        _ ->
          {:ok, nil}
      end
    end)
    |> Repo.transact()
    |> case do
      {:ok, %{seed: seed}} -> {:ok, Repo.preload(seed, :tags)}
      {:error, _, _, _} = error -> error
    end
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

  def get_sid(sid) do
    Repo.get_by(Seed, sid: sid)
  end

  def get_sid!(sid) do
    Repo.get_by!(Seed, sid: sid)
  end

  def list() do
    query = from s in Seed, order_by: [desc: s.updated_at]
    Repo.all(query)
  end

  def latest(name, seed_type) do
    Repo.one(
      from s in Seed,
        where: s.name == ^name and s.seed_type == ^seed_type,
        order_by: [desc: s.updated_at],
        limit: 1
    )
  end

  def latest_artifact(%__MODULE__{id: id}) do
    Repo.one(
      from s in Seed,
        where: s.id == ^id,
        order_by: [desc: s.updated_at]
    )
  end

  def latest_artifact_by_sid(sid) do
    Repo.one(
      from s in Seed,
        where: s.sid == ^sid,
        order_by: [desc: s.updated_at]
    )
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name, :seed_type, :org_id, :artifact])
    |> validate_inclusion(:seed_type, @seed_types)
    |> validate_required([:name, :seed_type, :org_id, :artifact])
    |> unique_constraint([:name, :seed_type, :org_id, :artifact], error_key: :unique_seed)
  end
end
