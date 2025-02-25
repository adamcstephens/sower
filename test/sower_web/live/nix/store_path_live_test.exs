defmodule SowerWeb.Nix.StorePathLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.NixFixtures

  @create_attrs %{path: "some path"}
  @update_attrs %{path: "some updated path"}
  @invalid_attrs %{path: nil}

  defp create_store_path(_) do
    store_path = store_path_fixture()
    %{store_path: store_path}
  end

  describe "Index" do
    setup [:create_store_path]

    test "lists all store_paths", %{conn: conn, store_path: store_path} do
      {:ok, _index_live, html} = live(conn, ~p"/nix/store_paths")

      assert html =~ "Listing Store paths"
      assert html =~ store_path.path
    end

    test "saves new store_path", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/nix/store_paths")

      assert index_live |> element("a", "New Store path") |> render_click() =~
               "New Store path"

      assert_patch(index_live, ~p"/nix/store_paths/new")

      assert index_live
             |> form("#store_path-form", store_path: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#store_path-form", store_path: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/nix/store_paths")

      html = render(index_live)
      assert html =~ "Store path created successfully"
      assert html =~ "some path"
    end

    test "updates store_path in listing", %{conn: conn, store_path: store_path} do
      {:ok, index_live, _html} = live(conn, ~p"/nix/store_paths")

      assert index_live |> element("#store_paths-#{store_path.id} a", "Edit") |> render_click() =~
               "Edit Store path"

      assert_patch(index_live, ~p"/nix/store_paths/#{store_path}/edit")

      assert index_live
             |> form("#store_path-form", store_path: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#store_path-form", store_path: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/nix/store_paths")

      html = render(index_live)
      assert html =~ "Store path updated successfully"
      assert html =~ "some updated path"
    end

    test "deletes store_path in listing", %{conn: conn, store_path: store_path} do
      {:ok, index_live, _html} = live(conn, ~p"/nix/store_paths")

      assert index_live |> element("#store_paths-#{store_path.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#store_paths-#{store_path.id}")
    end
  end

  describe "Show" do
    setup [:create_store_path]

    test "displays store_path", %{conn: conn, store_path: store_path} do
      {:ok, _show_live, html} = live(conn, ~p"/nix/store_paths/#{store_path}")

      assert html =~ "Show Store path"
      assert html =~ store_path.path
    end

    test "updates store_path within modal", %{conn: conn, store_path: store_path} do
      {:ok, show_live, _html} = live(conn, ~p"/nix/store_paths/#{store_path}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Store path"

      assert_patch(show_live, ~p"/nix/store_paths/#{store_path}/show/edit")

      assert show_live
             |> form("#store_path-form", store_path: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#store_path-form", store_path: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/nix/store_paths/#{store_path}")

      html = render(show_live)
      assert html =~ "Store path updated successfully"
      assert html =~ "some updated path"
    end
  end
end
