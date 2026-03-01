defmodule SowerWeb.PageControllerTest do
  use SowerWeb.ConnCase, async: true

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
