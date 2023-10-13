defmodule Sower.Forge.Hook do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hooks" do
    field :request, :map

    timestamps()
  end

  @doc false
  def changeset(hook, attrs) do
    hook
    |> cast(attrs, [:request])
    |> validate_required([:request])
  end
end
