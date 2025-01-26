defmodule SowerWeb.Forge.OauthController do
  use SowerWeb, :controller

  def callback(conn, params) do
    dbg(params)

    conn
    |> dbg()
    |> text("authenticated")
  end
end
