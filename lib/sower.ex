defmodule Sower do
  use Ash.Domain

  resources do
    resource Sower.Seed
    resource Sower.Inputs.Repository
  end
end
