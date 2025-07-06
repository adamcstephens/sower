defmodule Nix.Profile.Generation do
  use Xema

  @derive Jason.Encoder

  xema_struct do
    field :created, DateTime
    field :link, :string
    field :path, :string

    required [:created, :link, :path]
  end
end
