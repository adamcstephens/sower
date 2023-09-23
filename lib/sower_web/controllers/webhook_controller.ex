defmodule SowerWeb.WebhookController do
  use SowerWeb, :controller

  def handler(conn, _params) do
    json(conn, %{handled: true})
  end
end
