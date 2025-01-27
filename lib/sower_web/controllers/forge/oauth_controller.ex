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

    conn
    |> put_session(:oauth_code, code)
    |> delete_session(:return_to_forge)
    |> redirect(to: ~p"/forges/#{forge.id}")
  end
end
