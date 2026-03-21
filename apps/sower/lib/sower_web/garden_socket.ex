defmodule SowerWeb.GardenSocket do
  import Sower.Authorization
  require Logger
  use Phoenix.Socket

  channel("garden:*", SowerWeb.GardenChannel)
  channel("agent:*", SowerWeb.GardenChannel)

  @impl Phoenix.Socket
  def connect(%{"token" => token}, socket, _connect_info) do
    case token |> Base.decode64!() |> Sower.Accounts.AccessToken.authenticate() do
      {:ok, access_token} ->
        if access_token |> can() |> read?(Sower.Orchestration.Garden) do
          socket =
            socket
            |> assign(:access_token, access_token)
            |> assign(:conn_sid, SowerClient.Sid.generate("conn"))

          {:ok, socket}
        else
          Logger.error(
            msg: "Access token is not authorized to be a garden",
            access_token_sid: access_token.sid
          )

          {:error, :unauthorized}
        end

      {:error, error} ->
        Logger.error(msg: "Invalid authentication", error: error)
        {:error, :unauthorized}
    end
  end

  def connect(_, _socket, _connect_info) do
    Logger.error(msg: "unauthorized connection")
    {:error, :unauthorized}
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil
end
