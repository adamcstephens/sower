defmodule SowerWeb.AuthController do
  require Logger
  use SowerWeb, :controller

  def callback(conn, %{"code" => code}) do
    IO.inspect(code)
    conn
  end

  # def callback(conn, _params) do
  #   Logger.error("Failed to authenticate")
  #   conn
  # end
end
