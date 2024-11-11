defmodule SowerWeb.TokenAuth do
  use SowerWeb, :verified_routes

  import Plug.Conn
  require Logger

  def ensure_token_authenticated(conn, _opts) do
    with true <-
           conn.req_headers
           |> Enum.any?(fn {key, _value} -> key == "authorization" end),
         token <-
           conn.req_headers
           |> Enum.find(fn {key, _value} -> key == "authorization" end)
           |> Kernel.elem(1)
           |> String.split(" ")
           |> Enum.at(1),
         {:ok, access_token} <- Sower.Accounts.AccessToken.authenticate(token) do
      Sower.Repo.put_org_id(access_token.user.org_id)

      conn
      |> assign(:access_token, access_token)
    else
      {:error, err} ->
        Logger.error(~s"Unauthorized token received: #{err}")
        conn |> send_unauthorized()

      _ ->
        conn |> send_unauthorized()
    end
  end

  defp send_unauthorized(conn) do
    conn
    |> put_resp_header("content-type", "application/json")
    |> resp(:unauthorized, %{error: "unauthorized"} |> Jason.encode!())
    |> send_resp()
    |> halt()
  end
end
