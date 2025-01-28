defmodule SowerWeb.Forge.OauthController do
  use SowerWeb, :controller

  def login(conn, %{"id" => id}) do
    forge = Sower.Forge.get_connection!(id)

    {:ok, url} = Sower.Forge.Oauth.create_redirect_url(forge)

    conn
    |> put_session(:return_to_forge, id)
    |> redirect(external: url)
  end

  def callback(conn, %{"code" => code}) do
    id = get_session(conn, :return_to_forge)
    forge = Sower.Forge.get_connection!(id)
    {:ok, token} = Sower.Forge.Oauth.retrieve_token(forge, code)

    conn =
      case Sower.Forge.Oauth.set_token(token, forge.id, conn.assigns.current_user.id) do
        :ok -> put_flash(conn, :info, "Logged in to forge #{forge.name}")
        _ -> put_flash(conn, :error, "Failed to log in to forge")
      end

    conn
    |> delete_session(:return_to_forge)
    |> redirect(to: ~p"/forges/#{forge.id}")
  end
end
