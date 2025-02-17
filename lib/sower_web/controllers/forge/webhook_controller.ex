defmodule SowerWeb.Forge.WebhookController do
  use SowerWeb, :controller

  def post(conn, _params) do
    conn
    |> send_resp(200, "success")
  end
end
