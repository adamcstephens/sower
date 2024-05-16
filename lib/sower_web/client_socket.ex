defmodule SowerWeb.ClientSocket do
  use Phoenix.Socket

  channel("client:*", SowerWeb.ClientChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    jwk = %{
      "kty" => "oct",
      "k" => :jose_base64url.encode(Application.fetch_env!(:sower, :bootstrap_token))
    }

    case JOSE.JWT.verify(jwk, token) do
      {true, _jwt, _} -> {:ok, socket}
      _ -> {:error, "unauthorized"}
    end
  end

  @impl true
  def id(_socket), do: nil
end
