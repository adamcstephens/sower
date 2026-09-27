defmodule SowerWeb.CircusWebhookController do
  use SowerWeb, :controller

  def post(conn, _params) do
    config = Application.get_env(:sower, CircusClient, [])

    with secret when is_binary(secret) <- Keyword.get(config, :webhook_secret),
         [signature] <- get_req_header(conn, "x-circus-signature"),
         {:ok, body, conn} <- read_body(conn),
         expected <-
           "sha256=" <> Base.encode16(:crypto.mac(:hmac, :sha256, secret, body), case: :lower),
         true <- Plug.Crypto.secure_compare(expected, signature),
         {:ok, %{"build_id" => build_id}} when is_binary(build_id) <- Jason.decode(body) do
      case %{} |> Sower.Workers.CircusReconcile.new() |> Oban.insert() do
        {:ok, _job} -> send_resp(conn, 202, "")
        {:error, _reason} -> send_resp(conn, 503, "")
      end
    else
      _ -> send_resp(conn, 401, "")
    end
  end
end
