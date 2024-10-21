defmodule SowerWeb.AuthController do
  use SowerWeb, :controller
  plug SowerWeb.Ueberauth
  require Logger

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    case Sower.Accounts.find_or_create_user(auth.uid, auth.info) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Successfully authenticated.")
        |> SowerWeb.UserAuth.log_in_user(user)

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: "/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: auth}} = conn, _params) do
    Logger.error("Auth failure: #{inspect(auth)}")

    conn |> put_flash(:error, "Authentication failed.") |> redirect(to: "/")
  end
end
