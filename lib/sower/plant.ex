defmodule Sower.Plant do
  import Ecto.Query, warn: false
  alias Sower.Repo

  def list_trees() do
    Repo.all(Sower.Plant.Tree)
  end

  def create_tree(attrs \\ %{}) do
    %Sower.Plant.Tree{}
    |> Sower.Plant.Tree.changeset(attrs)
    |> Repo.insert()
  end

  def get_tree!(id), do: Repo.get!(Sower.Plant.Tree, id)

  def delete_tree(id) do
    get_tree!(id) |> Repo.delete()
  end
end
