defmodule SowerWeb.SeedLive.IndexTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  setup %{user: user} do
    Sower.Repo.put_org_id(user.org_id)
    :ok
  end

  test "renders seed list with default ordering", %{conn: conn} do
    seed_fixture(%{name: "alpha-host", seed_type: "nixos"})
    seed_fixture(%{name: "bravo-host", seed_type: "home-manager"})

    {:ok, _live, html} = live(conn, ~p"/seeds")

    assert html =~ "Listing Seeds"
    assert html =~ "alpha-host"
    assert html =~ "bravo-host"
  end

  test "filters by seed_type via query params", %{conn: conn} do
    seed_fixture(%{name: "nixos-seed", seed_type: "nixos"})
    seed_fixture(%{name: "hm-seed", seed_type: "home-manager"})

    path =
      "/seeds?filters[0][field]=seed_type&filters[0][op]=%3D%3D&filters[0][value]=nixos"

    {:ok, _live, html} = live(conn, path)

    assert html =~ "nixos-seed"
    refute html =~ "hm-seed"
  end

  test "filters by name via query params", %{conn: conn} do
    seed_fixture(%{name: "kale-host", seed_type: "nixos"})
    seed_fixture(%{name: "bravo-host", seed_type: "nixos"})

    path =
      "/seeds?filters[0][field]=name&filters[0][op]=ilike_and&filters[0][value]=kale"

    {:ok, _live, html} = live(conn, path)

    assert html =~ "kale-host"
    refute html =~ "bravo-host"
  end

  test "filter form triggers filtering", %{conn: conn} do
    seed_fixture(%{name: "kale-host", seed_type: "nixos"})
    seed_fixture(%{name: "bravo-host", seed_type: "home-manager"})

    {:ok, live, _html} = live(conn, ~p"/seeds")

    live
    |> element("form")
    |> render_change(%{"seed_type" => "nixos", "name" => ""})

    assert_patch(live)
    html = render(live)

    assert html =~ "kale-host"
    refute html =~ "bravo-host"
  end

  test "name filter narrows results", %{conn: conn} do
    seed_fixture(%{name: "kale-host", seed_type: "nixos"})
    seed_fixture(%{name: "bravo-host", seed_type: "nixos"})

    {:ok, live, _html} = live(conn, ~p"/seeds")

    live
    |> element("form")
    |> render_change(%{"name" => "kale", "seed_type" => ""})

    assert_patch(live)
    html = render(live)

    assert html =~ "kale-host"
    refute html =~ "bravo-host"
  end

  test "sortable column headers are links", %{conn: conn} do
    seed_fixture()

    {:ok, live, _html} = live(conn, ~p"/seeds")

    assert has_element?(live, "th a", "name")
    assert has_element?(live, "th a", "seed_type")
  end

  test "clicking sort header updates ordering", %{conn: conn} do
    seed_fixture(%{name: "alpha"})
    seed_fixture(%{name: "charlie"})
    seed_fixture(%{name: "bravo"})

    {:ok, live, _html} = live(conn, ~p"/seeds")

    live |> element("th a", "name") |> render_click()
    assert_patch(live)
    html = render(live)

    # Should show a sort indicator
    assert html =~ "\u25B4" or html =~ "\u25BE"
  end

  test "pagination is shown when results exceed page size", %{conn: conn} do
    for i <- 1..30, do: seed_fixture(%{name: "seed-#{String.pad_leading("#{i}", 3, "0")}"})

    {:ok, _live, html} = live(conn, ~p"/seeds")

    assert html =~ "Go to page 2"
  end

  test "pagination is not shown when results fit on one page", %{conn: conn} do
    seed_fixture()

    {:ok, _live, html} = live(conn, ~p"/seeds")

    refute html =~ "Go to page 2"
  end

  test "row click navigates to seed show page", %{conn: conn} do
    seed = seed_fixture(%{name: "clickable-seed"})

    {:ok, live, _html} = live(conn, ~p"/seeds")

    assert has_element?(live, ~s|td[phx-click]|)
    assert has_element?(live, ~s|a[href="/seeds/#{seed.sid}"]|, "Show")
  end
end
