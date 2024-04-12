defmodule SowerWeb.Plug.HealthCheck do
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: "/healthy"} = conn, _opts) do
    {:ok, _} = Sower.Repo.query("SELECT 1")

    conn
    |> send_resp(200, "")
    |> halt()
  end

  def call(conn, _opts), do: conn
end
