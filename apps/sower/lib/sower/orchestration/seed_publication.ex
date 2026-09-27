defmodule Sower.Orchestration.SeedPublication do
  use Sower.Schema

  import Ecto.Changeset

  alias Sower.Orchestration.Seed

  schema "seed_publications" do
    field :org_id, Ecto.UUID
    belongs_to :seed, Seed
    field :instance, :string
    field :seed_name, :string
    field :seed_type, :string
    field :project, :string
    field :job, :string
    field :branch, :string
    field :evaluation, :string
    field :build, :string
    field :revision, :string
    field :tags, :map
    field :source_order, :integer

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(publication, attrs) do
    publication
    |> cast(attrs, [
      :org_id,
      :seed_id,
      :instance,
      :project,
      :seed_name,
      :seed_type,
      :job,
      :branch,
      :evaluation,
      :build,
      :revision,
      :source_order,
      :tags
    ])
    |> validate_required([
      :org_id,
      :seed_id,
      :instance,
      :project,
      :seed_name,
      :seed_type,
      :job,
      :branch,
      :evaluation,
      :build,
      :revision,
      :source_order,
      :tags
    ])
    |> unique_constraint(
      [:org_id, :instance, :project, :job, :evaluation, :build, :seed_name, :seed_type],
      name: :seed_publications_identity_index
    )
  end
end
