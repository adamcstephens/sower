defmodule Sower.Seed do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower,
    extensions: [AshJsonApi.Resource]

  @derive {Jason.Encoder, only: [:id, :name, :type, :out_path, :branch, :repository_id]}

  @types [:nixos, :"home-manager", :"nix-darwin"]

  actions do
    defaults [:read, :create, :destroy]

    create :new_legacy do
      accept [:name, :type, :out_path]

      upsert? true
      upsert_identity :seed
      upsert_fields :updated_at
    end

    create :new do
      accept [:name, :type, :out_path, :branch]

      argument :repo_url, :string do
        allow_nil? false
      end

      upsert? true
      upsert_identity :seed
      upsert_fields :updated_at

      change manage_relationship(:repo_url, :repository,
               type: :create,
               on_match: :update,
               value_is_key: :url
             )
    end

    read :by_id do
      argument :id, :uuid do
        allow_nil? false
      end

      # only return one
      get? true

      filter expr(id == ^arg(:id))
    end

    read :latest do
      argument :name, :string do
        allow_nil? false
      end

      argument :type, :atom do
        allow_nil? false
        constraints one_of: @types
      end

      # only return one
      get? true

      prepare build(
                filter: expr(name == ^arg(:name) and type == ^arg(:type)),
                limit: 1,
                sort: [updated_at: :desc]
              )
    end

    read :by_path do
      argument :out_path, :string do
        allow_nil? false
      end

      # # only return one
      # get? true
      #
      prepare build(
                filter: expr(out_path == ^arg(:out_path)),
                limit: 1,
                sort: [updated_at: :desc]
              )
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :branch, :string

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @types
    end

    attribute :out_path, :string do
      allow_nil? false
      public? true
      constraints match: ~r|/nix/store/[a-z0-9]{32}-[a-z0-9]+|
    end
  end

  code_interface do
    define :by_id, args: [:id]
    define :by_path, args: [:out_path]
    define :new, args: [:name, :type, :out_path, :branch, :repo_url]
    define :new_legacy, args: [:name, :type, :out_path]
    define :latest, args: [:name, :type]
    define :read_all, action: :read
  end

  identities do
    identity :seed, [:name, :type, :out_path, :branch]
  end

  json_api do
    type "seed"

    routes do
      base "/seeds"

      get :read
    end
  end

  postgres do
    table "seeds"
    repo Sower.Repo

    references do
      reference :repository, on_delete: :delete
    end
  end

  relationships do
    belongs_to :repository, Sower.Inputs.Repository
  end
end
