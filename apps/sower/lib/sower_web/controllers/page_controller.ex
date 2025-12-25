defmodule SowerWeb.PageController do
  use SowerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end

  def health(conn, _params) do
    conn |> resp(200, ":ok")
  end
end
