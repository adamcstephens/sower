defmodule Sower.Client do
  use Ecto.Schema
  import Ecto.Changeset
  alias Sower.Repo

  @derive {Jason.Encoder, only: [:id, :name]}

  schema "clients" do
    field :name, :string

    timestamps()
  end

  def list() do
    Repo.all(Sower.Client)
  end

  defp changeset(seed, attrs) do
    seed
    |> cast(attrs, [:name])
    |> validate_required([:name, :seed_type])
  end
end
