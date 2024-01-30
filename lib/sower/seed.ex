# write a phoenix context for a model named seed with the following fields:
# name: string
# type: string

defmodule Sower.Seed do
  import Ecto.Query, warn: false
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
