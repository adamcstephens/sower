defmodule SowerWeb.BootstrapFallbackController do
  use Phoenix.Controller

  require Logger

  def call(conn, :error) do
    conn
    |> Plug.Conn.put_status(404)
    |> put_root_layout(false)
    |> Plug.Conn.halt()
    |> html("echo 'Error: failure rendering client script'; exit 1")
  end
end
