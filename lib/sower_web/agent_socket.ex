defmodule SowerWeb.AgentSocket do
  require Logger
  use Phoenix.Socket

  channel("agent:*", SowerWeb.AgentChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case token |> Base.decode64!() |> Sower.Accounts.AccessToken.authenticate() do
      {:ok, access_token} ->
        socket =
          socket
          |> assign(:access_token, access_token)
          |> assign(:conn_sid, Sower.Schema.Sid.generate("conn"))

        {:ok, socket}

      {:error, error} ->
        Logger.error(msg: "Invalid authentication", error: error)
        {:error, :unauthorized}
    end
  end

  def connect(_, _socket, _connect_info) do
    Logger.error(msg: "unauthorized connection")
    {:error, :unauthorized}
  end

  @impl true
  def id(_socket), do: nil
end
