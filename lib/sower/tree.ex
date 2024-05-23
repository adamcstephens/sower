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

    create :set_system_seeds do
      argument :profile_seed_id, :uuid
      argument :booted_seed_id, :uuid, allow_nil?: false
      argument :current_seed_id, :uuid, allow_nil?: false

      upsert? true
      # upsert_identity :id
      # upsert_fields :updated_at

      # change manage_relationship(:booted_seed_id, :booted_seed, type: :append_and_remove)
      # change manage_relationship(:current_seed_id, :current_seed, type: :append_and_remove)
      # change manage_relationship(:profile_seed_id, :current_seed, type: :append_and_remove)
      #
      change fn changeset, _ctx ->
        dbg(changeset)
        booted_seed = Ash.Changeset.get_argument(changeset, :booted_seed)

        booted_seed =
          Sower.Seed.new(
            booted_seed["name"],
            booted_seed["type"],
            booted_seed["out_path"],
            nil,
            nil
          )

        current_seed = Ash.Changeset.get_argument(changeset, :current_seed)

        current_seed =
          Sower.Seed.new(
            current_seed["name"],
            current_seed["type"],
            current_seed["out_path"],
            nil,
            nil
          )

        profile_seed = Ash.Changeset.get_argument(changeset, :profile_seed)

        profile_seed =
          Sower.Seed.new(
            profile_seed["name"],
            profile_seed["type"],
            profile_seed["out_path"],
            nil,
            nil
          )

        changeset
        |> Ash.Changeset.change_attribute(:booted_seed_id, booted_seed.id)
        |> Ash.Changeset.change_attribute(:current_seed_id, current_seed.id)
        |> Ash.Changeset.change_attribute(:profile_seed_id, profile_seed.id)
      end
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
    define :set_system_seeds, args: [:profile_seed_id, :booted_seed_id, :current_seed_id]
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
      reference :booted_seed
      reference :current_seed
      reference :latest_seed
      reference :profile_seed
    end
  end

  relationships do
    belongs_to :booted_seed, Sower.Seed, source_attribute: :booted_seed_id
    belongs_to :current_seed, Sower.Seed, source_attribute: :current_seed_id
    belongs_to :latest_seed, Sower.Seed, source_attribute: :latest_seed_id
    belongs_to :profile_seed, Sower.Seed, source_attribute: :profile_seed_id
  end
end
