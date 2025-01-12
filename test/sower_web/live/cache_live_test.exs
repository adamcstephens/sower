defmodule SowerWeb.CacheLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.NixFixtures

  @create_attrs %{public_key: "some public_key", url: "some url"}
  @update_attrs %{public_key: "some updated public_key", url: "some updated url"}
  @invalid_attrs %{public_key: nil, url: nil}

  defp create_cache(%{user: user}) do
    Sower.Repo.put_org_id(user.org_id)
    cache = cache_fixture()
    %{cache: cache}
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_cache]

    test "lists all nix_caches", %{conn: conn, cache: cache} do
      {:ok, _index_live, html} = live(conn, ~p"/nix_caches")

      assert html =~ "Listing Nix caches"
      assert html =~ cache.public_key
    end

    test "saves new cache", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/nix_caches")

      assert index_live |> element("a", "New Cache") |> render_click() =~
               "New Cache"

      assert_patch(index_live, ~p"/nix_caches/new")

      assert index_live
             |> form("#cache-form", cache: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#cache-form", cache: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/nix_caches")

      html = render(index_live)
      assert html =~ "Cache created successfully"
      assert html =~ "some public_key"
    end

    test "updates cache in listing", %{conn: conn, cache: cache} do
      {:ok, index_live, _html} = live(conn, ~p"/nix_caches")

      assert index_live |> element("#nix_caches-#{cache.id} a", "Edit") |> render_click() =~
               "Edit Cache"

      assert_patch(index_live, ~p"/nix_caches/#{cache}/edit")

      assert index_live
             |> form("#cache-form", cache: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#cache-form", cache: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/nix_caches")

      html = render(index_live)
      assert html =~ "Cache updated successfully"
      assert html =~ "some updated public_key"
    end

    test "deletes cache in listing", %{conn: conn, cache: cache} do
      {:ok, index_live, _html} = live(conn, ~p"/nix_caches")

      assert index_live |> element("#nix_caches-#{cache.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#nix_caches-#{cache.id}")
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_cache]

    test "displays cache", %{conn: conn, cache: cache} do
      {:ok, _show_live, html} = live(conn, ~p"/nix_caches/#{cache}")

      assert html =~ "Show Cache"
      assert html =~ cache.public_key
    end

    test "updates cache within modal", %{conn: conn, cache: cache} do
      {:ok, show_live, _html} = live(conn, ~p"/nix_caches/#{cache}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Cache"

      assert_patch(show_live, ~p"/nix_caches/#{cache}/show/edit")

      assert show_live
             |> form("#cache-form", cache: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#cache-form", cache: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/nix_caches/#{cache}")

      html = render(show_live)
      assert html =~ "Cache updated successfully"
      assert html =~ "some updated public_key"
    end
  end
end
