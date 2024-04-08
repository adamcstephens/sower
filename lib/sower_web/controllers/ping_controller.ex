defmodule SowerWeb.PingController do
  use SowerWeb, :controller

  def ping(conn, _) do
    {:ok, _} = Sower.Repo.query("PRAGMA database_list")

    text(conn, "ok")
  end
end
