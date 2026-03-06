defmodule Sower.Orchestration.SeedTag do
  use Sower.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:key, :value]}

  schema "seed_tags" do
    field :key, :string
    field :value, :string

    belongs_to :seed, Sower.Orchestration.Seed
  end

  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
