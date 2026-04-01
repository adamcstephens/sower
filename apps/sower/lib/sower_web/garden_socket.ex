defmodule SowerWeb.GardenSocket do
  import Sower.Authorization
  require Logger
  use Phoenix.Socket

  channel("garden:*", SowerWeb.GardenChannel)
  channel("agent:*", SowerWeb.GardenChannel)

  @impl Phoenix.Socket
  def connect(%{"token" => token}, socket, _connect_info) do
    case authenticate_token(token) do
      {:ok, access_token} ->
        socket =
          socket
          |> assign(:access_token, access_token)
          |> assign(:conn_sid, SowerClient.Sid.generate("conn"))

        {:ok, socket}

      {:error, error} ->
        Logger.error(msg: "Authentication failed", error: error)
        {:error, :unauthorized}
    end
  end

  def connect(_, _socket, _connect_info) do
    Logger.error(msg: "unauthorized connection")
    {:error, :unauthorized}
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil

  defp authenticate_token("boruta:" <> boruta_token) do
    case Boruta.Oauth.Authorization.AccessToken.authorize(value: boruta_token) do
      {:ok, oauth_token} ->
        case Sower.Orchestration.Garden.get_by_boruta_client_id(oauth_token.client.id) do
          nil ->
            Logger.error(
              msg: "No garden found for Boruta client",
              boruta_client_id: oauth_token.client.id
            )

            {:error, :unknown_client}

          garden ->
            {:ok,
             %Sower.GardenAuth.Context{
               org_id: garden.org_id,
               garden_id: garden.id,
               scope: oauth_token.scope
             }}
        end

      {:error, _} ->
        {:error, :invalid_boruta_token}
    end
  end

  defp authenticate_token(base64_token) do
    case base64_token |> Base.decode64!() |> Sower.Accounts.AccessToken.authenticate() do
      {:ok, access_token} ->
        if access_token |> can() |> read?(Sower.Orchestration.Garden) do
          {:ok, access_token}
        else
          Logger.error(
            msg: "Access token is not authorized to be a garden",
            access_token_sid: access_token.sid
          )

          {:error, :unauthorized}
        end

      {:error, error} ->
        {:error, error}
    end
  end
end
