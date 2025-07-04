defmodule SowerWeb.TokenAuth do
  use SowerWeb, :verified_routes

  import Plug.Conn
  require Logger

  def ensure_token_authenticated(conn, _opts) do
    ["Bearer " <> access_token] = get_req_header(conn, "authorization")

    case Sower.Accounts.AccessToken.authenticate(access_token) do
      {:ok, access_token} ->
        Sower.Repo.put_org_id(access_token.org_id)
        assign(conn, :access_token, access_token)

      {:error, err} ->
        Logger.error(msg: "Unauthorized token received", error: err)
        conn |> send_unauthorized()
    end
  end

  defp send_unauthorized(conn) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> resp(:unauthorized, %{error: "unauthorized"} |> Jason.encode!())
    |> put_status(401)
    |> send_resp()
    |> halt()
  end
end
