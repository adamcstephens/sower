defmodule Sower.Inputs.Repository do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  actions do
    defaults [:read, :destroy, create: :*, update: :*]

    create :new do
      accept [:url]

      primary? true
      upsert? true
      upsert_identity :url
    end

    read :by_id do
      argument :id, :uuid do
        allow_nil? false
      end

      # only return one
      get? true

      filter expr(id == ^arg(:id))
    end

  end

  attributes do
    uuid_primary_key :id

    attribute :url, :string do
      allow_nil? false
    end
  end

  identities do
    identity :url, [:url]
  end

  code_interface do
    define :by_id, args: [:id]
    define :read_all, action: :read
  end

  postgres do
    table "input_repositories"
    repo Sower.Repo
  end
end
