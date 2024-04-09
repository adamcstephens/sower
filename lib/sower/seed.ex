defmodule Sower.Seed do
  use Ash.Resource,
    data_layer: AshPostgres.DataLayer,
    domain: Sower

  actions do
    defaults([:read, :create, :destroy])

    create :new do
      accept([:name, :type])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :type, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:nixos, :home_manager, :nix_darwin])
    end
  end

  code_interface do
    define(:new, args: [:name, :type])
  end

  postgres do
    table("seeds")
    repo(Sower.Repo)
  end

  # relationships do
  #   belongs_to :tree, Sower.Tree
  # end
end

# def create_or_insert_seed(attrs \\ %{}) do
#   %Sower.Seed.Instance{}
#   |> Sower.Seed.Instance.changeset(attrs)
#   |> Repo.insert(
#     on_conflict: {:replace, [:updated_at]},
#     conflict_target: [:name, :type, :out_path]
#   )
# end
#
# def find_latest_seed(name, type) do
#   Sower.Seed.Instance
#   |> where([s], s.name == ^name)
#   |> where([s], s.type == ^type)
#   |> order_by([s], desc: s.updated_at)
#   |> first()
#   |> Repo.all()
#   |> List.first()
# end
