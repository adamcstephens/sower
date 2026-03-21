defmodule SowerWeb.PageControllerTest do
  use SowerWeb.ConnCase, async: true

  test "home renders mobile dropdown navigation using semantic HTML", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "mobile-nav-dropdown"
    assert html =~ "<summary"
    assert html =~ "Menu"
    assert html =~ "mobile-nav-dropdown-panel"
    assert html =~ ~s(href="/gardens")
    assert html =~ ~s(href="/seeds")
    assert html =~ ~s(href="/deployments")
  end

  test "home renders sign in as a button", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Sign In"
    assert html =~ "<button"
  end

  test "mobile dropdown styles include open and closed states" do
    css = File.read!("assets/css/app.css")

    assert css =~ ".mobile-nav-dropdown-panel"
    assert css =~ ".mobile-nav-dropdown[open] .mobile-nav-dropdown-panel"
    assert css =~ ".mobile-nav-dropdown-chevron"
    assert css =~ ".mobile-nav-dropdown[open] .mobile-nav-dropdown-chevron"
  end

  test "home renders auth feedback below header when auth_error flash is present", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> Phoenix.Controller.fetch_flash([])
      |> Phoenix.Controller.put_flash(:auth_error, "Authentication failed.")
      |> get(~p"/")

    html = html_response(conn, 200)

    assert html =~ "id=\"auth-feedback\""
    assert html =~ "data-auto-dismiss-ms=\"5000\""

    {header_index, _} = :binary.match(html, "</header>")
    {auth_feedback_index, _} = :binary.match(html, "id=\"auth-feedback\"")

    assert auth_feedback_index > header_index
  end
end
