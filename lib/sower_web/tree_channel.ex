defmodule SowerWeb.TreeChannel do
  use Phoenix.Channel

  def join("tree:all", _message, socket) do
    {:ok, socket}
  end

  def join("tree:" <> tree_name, _params, _socket) do
    {:error, %{reason: "unauthorized"}}
  end

  def handle_in("reply_ok_tuple", body, socket) do
    {:reply, {:ok, "success"}, socket}
  end
end
