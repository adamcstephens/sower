defmodule SowerWeb.ClientChannel do
  require Logger
  use Phoenix.Channel

  def join("client:all", _message, socket) do
    send(self(), :push_tree_id_to_client)
    # Logger.debug(~s"client:all joined by #{socket.assigns.tree_id}")
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

  def handle_in(
        "seed:submit",
        %{
          "name" => name,
          "seed_type" => seed_type,
          "out_path" => out_path
        } = _seed,
        socket
      ) do
    case Sower.Seed.submit(%{name: name, seed_type: seed_type, out_path: out_path}) do
      {:ok, %Sower.Seed{} = seed} ->
        {:reply, {:ok, %{seed_id: seed.id}}, socket}

      {:error, _err} ->
        {:reply, {:error, "failed to submit"}, socket}
    end
  end

  def handle_info(:push_tree_id_to_client, socket) do
    # push(socket, "tree:id", %{tree_id: socket.assigns.tree_id})
    {:noreply, socket}
  end
end
