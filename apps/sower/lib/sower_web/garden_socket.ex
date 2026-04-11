defmodule SowerWeb.GardenSocket do
  require Logger
  use Phoenix.Socket

  channel("garden:*", SowerWeb.GardenChannel)

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    case extract_token(connect_info) do
      {:ok, token} ->
        case authenticate_token(token) do
          {:ok, context} ->
            socket =
              socket
              |> assign(:access_token, context)
              |> assign(:conn_sid, SowerClient.Sid.generate("conn"))

            {:ok, socket}

          {:error, error} ->
            Logger.error(msg: "Authentication failed", error: error)
            {:error, :unauthorized}
        end

      :error ->
        Logger.error(msg: "unauthorized connection")
        {:error, :unauthorized}
    end
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil

  defp extract_token(%{x_headers: headers}) do
    case List.keyfind(headers, "x-auth-token", 0) do
      {_, "boruta:" <> _ = token} -> {:ok, token}
      {_, _} -> :error
      nil -> :error
    end
  end

  defp extract_token(_connect_info), do: :error

  defp authenticate_token("boruta:" <> boruta_token) do
    case authorize_boruta_token(boruta_token) do
      {:ok, oauth_token} ->
        case Sower.Orchestration.Garden.get_by_oauth_client_id(oauth_token.client.id) do
          nil ->
            Logger.error(
              msg: "No garden found for Boruta client",
              oauth_client_id: oauth_token.client.id
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

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp authorize_boruta_token(token) do
    Boruta.Oauth.Authorization.AccessToken.authorize(value: token)
  rescue
    ArgumentError ->
      Logger.error(
        msg: "Boruta token references a deleted OAuth client",
        token_prefix: String.slice(token, 0, 8)
      )

      {:error, :invalid_boruta_token}
  end
end
