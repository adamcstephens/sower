defmodule SowerWeb.AuthController do
  use SowerWeb, :controller
  plug Ueberauth
  require Logger

  def callback(%{assigns: %{ueberauth_auth: auth}} = conn, _params) do
    dbg(conn) |> redirect(to: "/")

    case {:ok, %{}} do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Successfully authenticated.")
        |> assign(:current_user, user)
        |> configure_session(renew: true)
        |> redirect(to: "/")

      {:error, reason} ->
        conn
        |> put_flash(:error, reason)
        |> redirect(to: "/")
    end
  end

  def callback(%{assigns: %{ueberauth_failure: auth}} = conn, params) do
    Logger.error("Auth failure: #{inspect(auth)}")

    conn |> put_flash(:error, "Authentication failed.") |> redirect(to: "/")
  end

  #
  #
  # def success(conn, _activity, user, _token) do
  #   return_to = get_session(conn, :return_to) || ~p"/"
  #
  #   conn
  #   |> delete_session(:return_to)
  #   # |> store_in_session(user)
  #   # TODO add back current user to conn |> assign(:current_user, user)
  #   |> redirect(to: return_to)
  # end
  #
  # def failure(conn, _activity, reason) do
  #   dbg(reason)
  #
  #   conn
  #   |> put_flash(:error, "Incorrect email or password")
  #   |> redirect(to: ~p"/sign-in")
  # end
  #
  # def sign_out(conn, _params) do
  #   return_to = get_session(conn, :return_to) || ~p"/"
  #
  #   conn
  #   |> clear_session()
  #   |> redirect(to: return_to)
  # end
end
