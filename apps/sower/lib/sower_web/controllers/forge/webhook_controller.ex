defmodule SowerWeb.Forge.WebhookController do
  use SowerWeb, :controller

  def post(conn, %{"repo_sid" => repo_sid}) do
    repo = Sower.Forge.get_global_repository_sid!(repo_sid)
    [event_type] = get_req_header(conn, "x-forgejo-event-type")

    Sower.Forge.WebhookStorage.put(
      repo,
      event_type,
      conn.params
    )

    conn
    |> send_resp(200, "success")
  end
end
