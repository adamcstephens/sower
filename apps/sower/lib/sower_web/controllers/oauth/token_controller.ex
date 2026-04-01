defmodule SowerWeb.OAuth.TokenController do
  use SowerWeb, :controller

  require Logger

  def create(conn, %{"grant_type" => "refresh_token", "refresh_token" => refresh_token}) do
    case Sower.GardenAuth.refresh(refresh_token) do
      {:ok, token_response} ->
        json(conn, token_response)

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_grant",
          error_description: "Refresh token is invalid or expired"
        })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "unsupported_grant_type",
      error_description: "Only refresh_token grant is supported"
    })
  end
end
