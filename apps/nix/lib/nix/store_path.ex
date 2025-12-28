defmodule Nix.StorePath do
  use TypedStruct

  typedstruct do
    field :path, String.t(), enforce: true
  end
end
