defmodule SowerWeb.PingController do
  use SowerWeb, :controller

  def ping(conn, _) do
    {:ok, _} = Sower.Repo.query("SELECT 1")

    text(conn, "ok")
  end
end
