defmodule SowerWeb.TreeChannel do
  use Phoenix.Channel

  def join("tree:all", _message, socket) do
    {:ok, socket}
  end

  def join("tree:" <> tree_name, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("register", %{"name" => name, "type" => type}, socket) do
    id =
      with {:ok, tree} <- Sower.Tree.register(name, type) do
        tree.id
      else
        {:error, _} -> Sower.Tree.find!(name, type) |> Map.get(:id)
      end

    {:reply, {:ok, id}, socket}
  end
end
