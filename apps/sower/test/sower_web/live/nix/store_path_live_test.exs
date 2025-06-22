defmodule SowerWeb.Nix.StorePathLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.NixFixtures

  defp create_store_path(_) do
    store_path = store_path_fixture()
    %{store_path: store_path}
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_store_path]

    test "lists all store_paths", %{conn: conn, store_path: store_path} do
      {:ok, _index_live, html} = live(conn, ~p"/nix/store_paths")

      assert html =~ "Listing Store paths"
      assert html =~ store_path.path
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_store_path]

    test "displays store_path", %{conn: conn, store_path: store_path} do
      {:ok, _show_live, html} = live(conn, ~p"/nix/store_paths/#{store_path}")

      assert html =~ "Show Store path"
      assert html =~ store_path.path
    end
  end
end
