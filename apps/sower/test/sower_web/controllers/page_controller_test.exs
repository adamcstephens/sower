defmodule SowerWeb.PageControllerTest do
  use SowerWeb.ConnCase, async: true

  test "home advertises installation metadata before signing in", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)

    assert html =~ ~s(rel="manifest" href="/manifest.webmanifest")
    assert html =~ ~s(rel="apple-touch-icon" sizes="180x180" href="/images/apple-touch-icon.png")
    assert html =~ ~s(name="theme-color" content="#ffffff")
    assert html =~ ~s(name="apple-mobile-web-app-capable" content="yes")
    assert html =~ ~s(name="apple-mobile-web-app-title" content="Sower")
  end

  test "installation manifest and icons are public", %{conn: conn} do
    response = get(conn, "/manifest.webmanifest")
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/manifest+json"]
    manifest = Jason.decode!(response.resp_body)

    assert manifest["name"] == "Sower"
    assert manifest["short_name"] == "Sower"
    assert manifest["id"] == "/"
    assert manifest["start_url"] == "/"
    assert manifest["scope"] == "/"
    assert manifest["display"] == "standalone"

    for {path, size} <- [
          {"/images/icon-192.png", 192},
          {"/images/icon-512.png", 512},
          {"/images/apple-touch-icon.png", 180}
        ] do
      image = get(build_conn(), path)
      assert image.status == 200
      assert get_resp_header(image, "content-type") == ["image/png"]

      assert <<137, "PNG\r\n", 26, "\n", 13::32, "IHDR", ^size::32, ^size::32, _::binary>> =
               image.resp_body
    end

    assert Enum.map(manifest["icons"], &{&1["src"], &1["sizes"], &1["type"]}) == [
             {"/images/icon-192.png", "192x192", "image/png"},
             {"/images/icon-512.png", "512x512", "image/png"}
           ]
  end

  test "home renders mobile dropdown navigation using semantic HTML", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "mobile-nav-dropdown"
    assert html =~ "<summary"
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
