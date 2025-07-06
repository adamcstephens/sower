defmodule Nix.StorePath do
  use Xema

  xema_struct do
    field :path, :string

    required [:path]
  end
end
