defmodule Sower do
  use Ash.Domain, extensions: [AshJsonApi.Domain]

  resources do
    resource Sower.Inputs.Repository
    resource Sower.Seed
    resource Sower.Tree
  end
end
