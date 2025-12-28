defmodule Nix.Profile.Generation do
  use TypedStruct

  @derive {Jason.Encoder, only: [:created, :link, :path]}

  typedstruct do
    field :created, DateTime.t(), enforce: true
    field :link, String.t(), enforce: true
    field :path, String.t(), enforce: true
  end
end
