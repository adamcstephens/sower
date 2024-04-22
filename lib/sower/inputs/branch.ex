defmodule Sower.Inputs.Branch do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    create :new do
      accept [:name]

      argument :repo, :string do
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

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
    end
  end

  code_interface do
    define :new, args: [:name, :repo]
    define :read_all, action: :read
  end

  identities do
    identity :repo_name, [:name, :repository_id]
  end

  postgres do
    table "input_branches"
    repo Sower.Repo

    references do
      reference :repository, on_delete: :delete
    end
  end

  relationships do
    belongs_to :repository, Sower.Inputs.Repository do
      allow_nil? false
    end
  end
end
