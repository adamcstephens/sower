defmodule SowerWeb.AgentSocket do
  import Sower.Authorization
  require Logger
  use Phoenix.Socket

  channel("agent:*", SowerWeb.AgentChannel)

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case token |> Base.decode64!() |> Sower.Accounts.AccessToken.authenticate() do
      {:ok, access_token} ->
        if access_token |> can() |> read?(Sower.Orchestration.Agent) do
          socket =
            socket
            |> assign(:access_token, access_token)
            |> assign(:conn_sid, SowerClient.Schemas.Sid.generate("conn"))

          {:ok, socket}
        else
          Logger.error(
            msg: "Access token is not authorized to be an agent",
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

  @impl true
  def id(_socket), do: nil
end
