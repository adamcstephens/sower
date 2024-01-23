defmodule Sower.Seed.Instance do
  use Ecto.Schema
  import Ecto.Changeset

  # json support
  @derive {Jason.Encoder, only: [:id, :name, :type, :out_path]}

  schema "seeds" do
    field :name, :string
    field :type, :string
    field :out_path, :string

    timestamps()
  end

  def changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :type, :out_path])
    |> unique_constraint(:name, name: "seeds_name_out_path_index")
    |> validate_required([:name, :type, :out_path])
    |> validate_inclusion(:type, ["nixos", "home-manager", "darwin"])
    |> validate_format(:out_path, ~r/\/nix\/store\/[a-z0-9]{32}-[a-z0-9]+/,
      message: "must be a valid nix store path"
    )
  end
end
