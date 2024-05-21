defmodule SowerWeb.ClientSocket do
  use Phoenix.Socket

  channel("client:*", SowerWeb.ClientChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    signer = Joken.Signer.create("HS256", Application.fetch_env!(:sower, :bootstrap_token))

    case Joken.Signer.verify(token, signer) do
      {:ok, _} -> {:ok, socket}
      _ -> {:error, "unauthorized"}
    end
  end

  @impl true
  def id(_socket), do: nil
end
