defmodule Sower do
  use Ash.Domain

  resources do
    resource Sower.Seed
  end
end
