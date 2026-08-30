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

      {:error, :unknown_client} ->
        invalid_client(conn, "unknown_client", "Client is not registered")

      {:error, {:assertion_expired, _skew}} ->
        invalid_client(
          conn,
          "assertion_expired",
          "Client assertion is expired; check the clock and retry"
        )

      {:error, :invalid_signature} ->
        invalid_client(
          conn,
          "invalid_signature",
          "Client assertion signature does not match the registered key"
        )

      {:error, _} ->
        invalid_client(conn, "invalid_assertion", "Client assertion is invalid")
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

  defp invalid_client(conn, reason, description) do
    conn
    |> put_status(:bad_request)
    |> json(%{
      error: "invalid_client",
      error_reason: reason,
      error_description: description
    })
  end
end
