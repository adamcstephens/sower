defmodule SowerWeb.AuthControllerTest do
  use SowerWeb.ConnCase, async: true

  alias SowerWeb.AuthController

  setup %{conn: conn} do
    conn =
      conn
      |> Map.replace!(:secret_key_base, SowerWeb.Endpoint.config(:secret_key_base))
      |> init_test_session(%{})
      |> fetch_flash()

    %{conn: conn}
  end

  test "callback/2 successful authentication does not set success flash", %{conn: conn} do
    auth = %Ueberauth.Auth{
      uid: Ecto.UUID.generate(),
      info: %Ueberauth.Auth.Info{name: "Test User", email: "test-user@example.com"}
    }

    conn = conn |> assign(:ueberauth_auth, auth) |> AuthController.callback(%{})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
    assert Phoenix.Flash.get(conn.assigns.flash || %{}, :info) == nil
    assert Phoenix.Flash.get(conn.assigns.flash || %{}, :auth_error) == nil
  end

  test "callback/2 failed user creation sets login-specific flash", %{conn: conn} do
    auth = %Ueberauth.Auth{
      uid: Ecto.UUID.generate(),
      info: %Ueberauth.Auth.Info{name: "Broken User", email: "invalid-email"}
    }

    conn = conn |> assign(:ueberauth_auth, auth) |> AuthController.callback(%{})

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :auth_error) == "Failed to authenticate"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
  end

  test "callback/2 ueberauth failure sets login-specific flash", %{conn: conn} do
    conn =
      conn
      |> assign(:ueberauth_failure, %{reason: :invalid_state})
      |> AuthController.callback(%{})

    assert redirected_to(conn) == ~p"/"
    assert Phoenix.Flash.get(conn.assigns.flash, :auth_error) == "Authentication failed."
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == nil
  end
end
