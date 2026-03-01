defmodule SowerWeb.AuthController do
  use SowerWeb, :controller
  plug SowerWeb.Ueberauth
  require Logger

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Sower.Accounts.find_or_create_user(auth.uid, auth.info) do
      {:ok, user} ->
        SowerWeb.UserAuth.log_in_user(conn, user)

      {:error, reason} ->
        Logger.error(msg: "Failed to authenticate", reason: reason)

        conn
        |> put_flash(:auth_error, "Failed to authenticate")
        |> redirect(to: "/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: auth}} = conn, _params) do
    Logger.error(msg: "Auth failure", auth: inspect(auth))

    conn |> put_flash(:auth_error, "Authentication failed.") |> redirect(to: "/")
  end
end
