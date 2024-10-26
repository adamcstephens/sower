defmodule SowerWeb.TokenAuth do
  use SowerWeb, :verified_routes

  import Plug.Conn

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
         {:ok, user} <- Sower.Accounts.AccessToken.authenticate(token) do
      Sower.Repo.put_org_id(user.org_id)
      conn
    else
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
