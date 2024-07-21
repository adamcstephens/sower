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
        "seed:submit",
        %{
          "name" => name,
          "seed_type" => seed_type,
          "out_path" => out_path
        } = seed,
        socket
      ) do
    case Sower.Seed.new(name, seed_type, out_path, nil, nil) do
      {:ok, %Sower.Seed{} = seed} ->
        {:reply, {:ok, %{seed_id: seed.id}}, socket}

      {:error, _err} ->
        {:reply, {:error, "failed to submit"}, socket}
    end
  end

  def handle_info(:push_tree_id_to_client, socket) do
    push(socket, "tree:id", %{tree_id: socket.assigns.tree_id})
    {:noreply, socket}
  end
end
