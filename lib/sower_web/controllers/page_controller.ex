defmodule SowerWeb.PageController do
  use SowerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
