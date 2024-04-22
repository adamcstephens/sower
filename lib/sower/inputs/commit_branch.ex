defmodule Sower.Inputs.CommitBranch do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  postgres do
    table "input_commit_branches"
    repo Sower.Repo
  end

  relationships do
    belongs_to :commit, Sower.Inputs.Commit, primary_key?: true, allow_nil?: false
    belongs_to :branch, Sower.Inputs.Branch, primary_key?: true, allow_nil?: false
  end
end
