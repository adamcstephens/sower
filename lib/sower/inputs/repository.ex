defmodule Sower.Inputs.Repository do
  use Sower.Schema
  import Ecto.Changeset

  schema "repositories" do
    field :url, :string

    timestamps()
  end

  @doc false
  def changeset(repository, attrs) do
    repository
    |> cast(attrs, [:url])
    |> validate_required([:url])
  end
end
