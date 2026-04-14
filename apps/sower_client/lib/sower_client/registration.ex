defmodule SowerClient.Registration do
  require Logger

  def register(%Req.Request{} = req, name, public_key_pem) do
    case Req.post(req,
           url: "/gardens/register",
           json: %{
             name: name,
             public_key: public_key_pem
           }
         ) do
      {:ok, %{status: 201, body: body}} ->
        {:ok,
         %{
           garden_sid: body["sid"],
           client_id: body["oauth_credentials"]["client_id"]
         }}

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
