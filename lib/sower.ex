defmodule Sower do
  use Ash.Domain

  resources do
    resource Sower.Seed
    resource Sower.Inputs.Branch
    resource Sower.Inputs.Commit
    resource Sower.Inputs.CommitBranch
    resource Sower.Inputs.Repository
  end
end
