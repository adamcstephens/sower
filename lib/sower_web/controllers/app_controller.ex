defmodule SowerWeb.AppController do
  use SowerWeb, :controller

  action_fallback SowerWeb.AppFallbackController

  def client_script(conn, _params) do
    case Application.fetch_env(:sower, :clients) do
      {:ok, clients} ->
        conn
        |> assign(:clients, clients)
        |> assign(:nix_caches, Application.fetch_env!(:sower, :nix_caches))
        |> put_root_layout(false)
        |> render(:client_script, layout: false)

      :error ->
        conn
        |> Plug.Conn.put_status(404)
        |> put_root_layout(false)
        |> Plug.Conn.halt()
        |> html("echo 'Error: client paths not configured on sower server'")
    end
  end
end
