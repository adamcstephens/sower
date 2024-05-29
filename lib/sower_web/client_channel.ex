defmodule SowerWeb.ClientChannel do
  require Logger
  use Phoenix.Channel

  def join("client:all", _message, socket) do
    send(self(), :push_tree_id_to_client)
    Logger.debug(~s"client:all joined by #{socket.assigns.tree_id}")
    {:ok, socket}
  end

  def join("client:" <> client_name, _params, socket = %{assigns: %{tree_id: tree_id}}) do
    if tree_id == client_name do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_topic, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("register", %{"name" => name, "type" => type}, socket) do
    id =
      with {:ok, client} <- Sower.Tree.register(name, type) do
        client.id
      else
        {:error, _} -> Sower.Tree.find!(name, type) |> Map.get(:id)
      end

    {:reply, {:ok, id}, socket |> assign(:tree_id, id)}
  end

  def handle_in(
        "seed:sync",
        %{
          "booted_seed" => booted_seed,
          "current_seed" => current_seed,
          "profile_seed" => profile_seed
        },
        socket
      ) do
    tree =
      Sower.Tree.by_id(socket.assigns.tree_id)
      |> Ash.load([:booted_seed, :current_seed, :profile_seed, :latest_seed])

    # res =
    #   case Sower.Tree.set_system_seeds(
    #          tree,
    #          profile_seed["id"],
    #          booted_seed["id"],
    #          current_seed["id"]
    #        )
    #        |> dbg() do
    #     {:ok, _} -> {:reply, {:ok, "yes"}, socket}
    #     {:error, _} -> {:reply, {:error, "fail"}, socket}
    #   end

    {:reply, {:ok, "TODO"}, socket}
  end

  def handle_info(:push_tree_id_to_client, socket) do
    push(socket, "tree:id", %{tree_id: socket.assigns.tree_id})
    {:noreply, socket}
  end
end
