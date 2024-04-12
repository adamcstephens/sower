defmodule Sower.Seed do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  @types [:nixos, :"home-manager", :"nix-darwin"]
  @derive {Jason.Encoder, only: [:id, :name, :type, :out_path]}

  actions do
    defaults([:read, :create, :destroy])

    create :new do
      accept([:name, :type, :out_path])
      upsert?(true)
      upsert_identity(:seed)
      upsert_fields(:updated_at)
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

      prepare build(filter: expr(name == ^arg(:name)), limit: 1, sort: [updated_at: :desc])
    end
  end

  attributes do
    uuid_primary_key(:id)
    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @types)
    end

    attribute :out_path, :string do
      allow_nil?(false)
      public?(true)
      constraints match: ~r|/nix/store/[a-z0-9]{32}-[a-z0-9]+|
    end
  end

  code_interface do
    define(:by_id, args: [:id])
    define(:new, args: [:name, :type, :out_path])
    define(:latest, args: [:name, :type])
    define(:read_all, action: :read)
  end

  identities do
    identity(:seed, [:name, :type, :out_path])
  end

  postgres do
    table("seeds")
    repo(Sower.Repo)
  end
end
