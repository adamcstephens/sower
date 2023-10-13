defmodule SowerWeb.WebhookController do
  use SowerWeb, :controller

  def handler(conn, params) do
    Sower.Forge.create_hook(%{request: params})
    json(conn, %{handled: true})
  end
end
