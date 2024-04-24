defmodule Sower.Inputs.CommitBranch do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
    create :new_commit do

      argument :branch_name, :string do
        allow_nil? false
      end

      argument :repo_url, :string do
        allow_nil? false
      end

      primary? true
      upsert? true
      upsert_identity :repo_name

      change manage_relationship(:repo, :repository,
               type: :create,
               on_match: :update,
               value_is_key: :url
             )
    end
  end

      accept [:branch_name, :repo_url]

  postgres do
    table "input_commit_branches"
    repo Sower.Repo
  end

  relationships do
    belongs_to :commit, Sower.Inputs.Commit, primary_key?: true, allow_nil?: false
    belongs_to :branch, Sower.Inputs.Branch, primary_key?: true, allow_nil?: false
  end
end
