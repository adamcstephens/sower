defmodule SowerWeb.FallbackController do
  use SowerWeb, :controller

  def call(conn, {:error, %Ash.Error.Query.NotFound{}}) do
    conn
    |> put_status(:not_found)
    |> put_view(html: SowerWeb.ErrorHTML, json: SowerWeb.ErrorJSON)
    |> render(:"404", %{detail: "not found"})
  end
end
