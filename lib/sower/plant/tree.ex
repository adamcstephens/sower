defmodule Sower.Plant.Tree do
  use Ecto.Schema
  import Ecto.Changeset

  schema "trees" do
    field :name, :string

    # maybe have agent gen a cert and store it, with optional approval
    # field :cert, :string

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
