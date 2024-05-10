defmodule Sower.Tree do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower,
    extensions: [AshJsonApi.Resource]

  @derive {Jason.Encoder, only: [:id, :name, :type]}

  @types [:nixos, :"home-manager", :"nix-darwin"]

  actions do
    defaults [:read]

    create :register do
      accept [:name, :type]
    end

    read :by_id do
      argument :id, :uuid do
        allow_nil? false
      end

      # only return one
      get? true

      filter expr(id == ^arg(:id))
    end

    read :find do
      argument :name, :string, allow_nil?: false
      argument :type, :string, allow_nil?: false

      get? true

      filter expr(name == ^arg(:name) && type == ^arg(:type))
    end

    update :set_seed do
      require_atomic? false

      argument :seed_id, :uuid do
        allow_nil? false
      end

      change manage_relationship(:seed_id, :seed, type: :append_and_remove)
    end
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :type, :atom do
      allow_nil? false
      public? true
      constraints one_of: @types
    end
  end

  code_interface do
    define :by_id, args: [:id]
    define :find, args: [:name, :type]
    define :set_seed, args: [:seed_id]
    define :read_all, action: :read
    define :register, args: [:name, :type]
  end

  identities do
    identity :tree, [:name, :type]
  end

  json_api do
    type "tree"

    routes do
      base "/trees"

      get :read
    end
  end

  postgres do
    table "trees"
    repo Sower.Repo

    references do
      reference :seed
    end
  end

  relationships do
    belongs_to :seed, Sower.Seed
  end
end
