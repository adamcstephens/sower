defmodule Sower.Seed do
  import Ecto.Query
  alias Sower.Repo

  def list_seeds do
    Repo.all(Sower.Seed.Instance)
  end

  def create_or_insert_seed(attrs \\ %{}) do
    %Sower.Seed.Instance{}
    |> Sower.Seed.Instance.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:updated_at]},
      conflict_target: [:name, :type, :out_path]
    )
  end

  def find_latest_seed(name, type) do
    Sower.Seed.Instance
    |> where([s], s.name == ^name)
    |> where([s], s.type == ^type)
    |> order_by([s], desc: s.updated_at)
    |> first()
    |> Repo.all()
    |> List.first()
  end

  def get_seed!(id), do: Repo.get!(Sower.Seed.Instance, id)

  def update_seed(id, attrs \\ %{}) do
    seed = get_seed!(id)

    seed
    |> Sower.Seed.Instance.changeset(attrs)
    |> Repo.update()
  end

  def delete_seed(id) do
    get_seed!(id)
    |> Repo.delete()
  end
end
