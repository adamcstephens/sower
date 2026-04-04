defmodule SowerWeb.OAuth.TokenController do
  use SowerWeb, :controller

  require Logger

  def create(conn, %{
        "grant_type" => "client_credentials",
        "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion" => client_assertion
      }) do
    case Sower.GardenAuth.issue(client_assertion) do
      {:ok, token_response} ->
        json(conn, token_response)

      {:error, _} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error: "invalid_client",
          error_description: "Client assertion is invalid"
        })
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "unsupported_grant_type",
      error_description: "Only client_credentials grant with JWT client assertion is supported"
    })
  end
end
