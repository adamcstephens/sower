defmodule SowerClient.Auth do
  @moduledoc """
  Client functions for authentication verification.
  """

  alias SowerClient.Auth.TokenInfo

  def verify() do
    verify(SowerClient.ApiClient.new())
  end

  def verify(%Req.Request{} = req) do
    case Req.get(req, url: "/auth/verify") do
      {:ok, %{status: 200, body: body}} ->
        TokenInfo.cast(body)

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{body: %{"error" => error}}} ->
        {:error, error}

      {:ok, response} ->
        {:error, response}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:connection_error, reason}}

      {:error, _} = err ->
        err
    end
  end
end
