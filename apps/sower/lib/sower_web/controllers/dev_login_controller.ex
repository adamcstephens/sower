if Mix.env() in [:dev, :test] do
  defmodule SowerWeb.DevLoginController do
    use SowerWeb, :controller

    alias Sower.Accounts
    alias Sower.Accounts.User
    alias Sower.Repo

    require Logger

    @dev_oidc_id "00000000-0000-4000-8000-000000000000"
    @dev_email "dev@localhost"
    @dev_name "Dev User"

    def login(conn, %{"token" => token}) do
      if valid_token?(token) do
        log_in_dev_user(conn)
      else
        reject(conn)
      end
    end

    def login(conn, _params) do
      render(conn, :index,
        users: Repo.all(User, skip_org_id: true),
        token: System.get_env("SOWER_DEV_LOGIN_TOKEN"),
        dev_email: @dev_email
      )
    end

    def create(conn, %{"token" => token, "sid" => "default"}) do
      if valid_token?(token) do
        log_in_dev_user(conn)
      else
        reject(conn)
      end
    end

    def create(conn, %{"token" => token, "sid" => sid}) do
      if valid_token?(token) do
        SowerWeb.UserAuth.log_in_user(conn, User.get_by_sid!(sid))
      else
        reject(conn)
      end
    end

    defp log_in_dev_user(conn) do
      {:ok, user} =
        Accounts.find_or_create_user(@dev_oidc_id, %Ueberauth.Auth.Info{
          name: @dev_name,
          email: @dev_email
        })

      SowerWeb.UserAuth.log_in_user(conn, user)
    end

    defp valid_token?(token) do
      expected = System.get_env("SOWER_DEV_LOGIN_TOKEN")

      expected != nil and Plug.Crypto.secure_compare(token, expected)
    end

    defp reject(conn) do
      Logger.warning(msg: "Dev login rejected", reason: "invalid or missing token")

      conn
      |> put_status(:unauthorized)
      |> text("unauthorized")
    end
  end

  defmodule SowerWeb.DevLoginHTML do
    use SowerWeb, :html

    embed_templates "dev_login_html/*"
  end
end
