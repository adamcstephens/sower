defmodule Sower.Inputs.Repository do
  use Sower.Schema
  # import Ecto.Changeset

  alias Sower.Repo

  schema "repositories" do
    field :url, :string
    field :org_id, Ecto.UUID

    timestamps()
  end

  def get!(id) do
    Repo.get!(Sower.Inputs.Repository, id)
  end

  def list() do
    Repo.all(Sower.Inputs.Repository)
  end

  # defp changeset(repository, attrs) do
  #   repository
  #   |> cast(attrs, [:url])
  #   |> validate_required([:url])
  # end
end
