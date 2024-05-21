defmodule SowerWeb.ClientChannel do
  use Phoenix.Channel

  def join("client:all", _message, socket) do
    {:ok, socket}
  end

  def join("client:" <> client_name, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("register", %{"name" => name, "type" => type}, socket) do
    id =
      with {:ok, client} <- Sower.Tree.register(name, type) do
        client.id
      else
        {:error, _} -> Sower.Tree.find!(name, type) |> Map.get(:id)
      end

    {:reply, {:ok, id}, socket}
  end
end
