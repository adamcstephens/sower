defmodule SowerWeb.GardenSocket do
  import Sower.Authorization
  require Logger
  use Phoenix.Socket

  channel("garden:*", SowerWeb.GardenChannel)

  @impl Phoenix.Socket
  def connect(params, socket, connect_info) do
    case extract_token(params, connect_info) do
      {:ok, token} ->
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

      :error ->
        Logger.error(msg: "unauthorized connection")
        {:error, :unauthorized}
    end
  end

  @impl Phoenix.Socket
  def id(_socket), do: nil

  defp extract_token(params, %{x_headers: headers}) do
    case List.keyfind(headers, "x-auth-token", 0) do
      {_, token} -> {:ok, token}
      nil -> extract_token_from_params(params)
    end
  end

  defp extract_token(params, _connect_info), do: extract_token_from_params(params)

  # Fallback for query param (pre-0.8.0 garden compat)
  defp extract_token_from_params(%{"token" => token}), do: {:ok, token}
  defp extract_token_from_params(_params), do: :error

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

  defp authenticate_token(base64_token) do
    with {:ok, decoded} <- Base.decode64(base64_token),
         {:ok, access_token} <- Sower.Accounts.AccessToken.authenticate(decoded) do
      if access_token |> can() |> create?(Sower.Orchestration.Garden) do
        {:ok, access_token}
      else
        Logger.error(
          msg: "Access token is not authorized to be a garden",
          access_token_sid: access_token.sid
        )

        {:error, :unauthorized}
      end
    else
      :error ->
        {:error, :invalid_token}

      {:error, error} ->
        {:error, error}
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
