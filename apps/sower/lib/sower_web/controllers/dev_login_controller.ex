if Mix.env() in [:dev, :test] do
  defmodule SowerWeb.DevLoginController do
    use SowerWeb, :controller

    require Logger

    def login(conn, %{"token" => token}) do
      expected = System.get_env("SOWER_DEV_LOGIN_TOKEN")

      if expected != nil and Plug.Crypto.secure_compare(token, expected) do
        {:ok, user} =
          Sower.Accounts.find_or_create_user(
            "dev-user-oidc-id",
            %Ueberauth.Auth.Info{
              name: "Dev User",
              email: "dev@localhost"
            }
          )

        SowerWeb.UserAuth.log_in_user(conn, user)
      else
        Logger.warning(msg: "Dev login rejected", reason: "invalid or missing token")

        conn
        |> put_status(:unauthorized)
        |> text("unauthorized")
      end
    end

    def login(conn, _params) do
      conn
      |> put_status(:bad_request)
      |> text("missing token parameter")
    end
  end
end
