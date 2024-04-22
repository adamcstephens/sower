defmodule Sower.Inputs.Commit do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    create :new do
      accept [:hash]

      argument :branch, :string do
        allow_nil? false
      end

      argument :repo, :string do
        allow_nil? false
      end

      primary? true
      upsert? true
      upsert_identity :repo_hash

      change manage_relationship(:repo, :repository,
               type: :create,
               on_match: :update,
               value_is_key: :url
             )

      change manage_relationship(:branch, :branches,
               type: :create,
               on_match: :update,
               value_is_key: :name
             )

      # change manage_relationship(:branch, :branches, type: :create)
      # change manage_relationship(
      #          :branches,
      #          :branches,
      #          type: :create
      #        )
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :hash, :string do
      allow_nil? false
      public? true

      constraints min_length: 40,
                  max_length: 40,
                  match: ~r/[0-9a-f]*/
    end
  end

  code_interface do
    define :new, args: [:hash, :repo, :branch]
    define :read_all, action: :read
  end

  identities do
    identity :repo_hash, [:hash, :repository_id]
  end

  postgres do
    table "input_commits"
    repo Sower.Repo

    references do
      reference :repository, on_delete: :delete
    end
  end

  relationships do
    belongs_to :repository, Sower.Inputs.Repository do
      allow_nil? false
    end

    many_to_many :branches, Sower.Inputs.Branch do
      through Sower.Inputs.CommitBranch
      source_attribute_on_join_resource :commit_id
      destination_attribute_on_join_resource :branch_id
    end
  end
end
