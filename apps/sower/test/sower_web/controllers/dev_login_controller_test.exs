defmodule SowerWeb.DevLoginControllerTest do
  use SowerWeb.ConnCase, async: false

  import Sower.AccountsFixtures

  @token "dev-login-test-token"

  setup do
    previous = System.get_env("SOWER_DEV_LOGIN_TOKEN")
    System.put_env("SOWER_DEV_LOGIN_TOKEN", @token)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("SOWER_DEV_LOGIN_TOKEN")
        value -> System.put_env("SOWER_DEV_LOGIN_TOKEN", value)
      end
    end)

    :ok
  end

  describe "GET /dev/login" do
    test "lists seeded users to log in as", %{conn: conn} do
      user = user_fixture()

      response = conn |> get(~p"/dev/login") |> html_response(200)

      assert response =~ user.email
      assert response =~ user.sid
    end

    test "offers the default dev user when none are seeded", %{conn: conn} do
      response = conn |> get(~p"/dev/login") |> html_response(200)

      assert response =~ "dev@localhost"
    end

    test "logs in directly when the token is given", %{conn: conn} do
      conn = get(conn, ~p"/dev/login?token=#{@token}")

      assert get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/"
    end

    test "rejects an invalid token", %{conn: conn} do
      conn = get(conn, ~p"/dev/login?token=nope")

      refute get_session(conn, :user_token)
      assert response(conn, 401)
    end
  end

  describe "POST /dev/login" do
    test "logs in as the chosen user", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/dev/login", %{"token" => @token, "sid" => user.sid})

      assert token = get_session(conn, :user_token)
      assert Sower.Accounts.User.get_by_session_token(token).id == user.id
      assert redirected_to(conn) == ~p"/"
    end

    test "creates and logs in the default dev user", %{conn: conn} do
      conn = post(conn, ~p"/dev/login", %{"token" => @token, "sid" => "default"})

      assert token = get_session(conn, :user_token)
      assert Sower.Accounts.User.get_by_session_token(token).email == "dev@localhost"
    end

    test "rejects an invalid token", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/dev/login", %{"token" => "nope", "sid" => user.sid})

      refute get_session(conn, :user_token)
      assert response(conn, 401)
    end
  end
end
