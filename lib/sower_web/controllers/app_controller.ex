defmodule SowerWeb.AppController do
  use SowerWeb, :controller

  def client_script(conn, _params) do
    case Application.fetch_env(:sower, :client_store_path) do
      {:ok, client_store_path} ->
        render(conn |> put_root_layout(false), :client_script,
          layout: false,
          client_store_path: client_store_path
        )

      :error ->
        html(conn |> Plug.Conn.put_status(404) |> Plug.Conn.halt(), "not found")
    end
  end
end
