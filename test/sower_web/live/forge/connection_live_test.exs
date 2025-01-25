defmodule SowerWeb.Forge.ConnectionLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.ForgeFixtures

  @create_attrs %{
    name: "some name",
    type: :forgejo,
    url: "some url",
    client_id: "some client_id",
    client_secret: "some client_secret"
  }
  @update_attrs %{
    name: "some updated name",
    type: :forgejo,
    url: "some updated url",
    client_id: "some updated client_id",
    client_secret: "some updated client_secret"
  }
  @invalid_attrs %{name: nil, type: nil, url: nil, client_id: nil, client_secret: nil}

  defp create_connection(%{user: %{org_id: org_id}}) do
    connection = connection_fixture(%{org_id: org_id})
    %{connection: connection}
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_connection]

    test "lists all forges", %{conn: conn, connection: connection} do
      {:ok, _index_live, html} = live(conn, ~p"/forges")

      assert html =~ "Listing Forges"
      assert html =~ connection.name
    end

    test "saves new connection", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/forges")

      assert index_live |> element("a", "New Connection") |> render_click() =~
               "New Connection"

      assert_patch(index_live, ~p"/forges/new")

      assert index_live
             |> form("#connection-form", connection: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#connection-form", connection: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/forges")

      html = render(index_live)
      assert html =~ "Connection created successfully"
      assert html =~ "some name"
    end

    test "updates connection in listing", %{conn: conn, connection: connection} do
      {:ok, index_live, _html} = live(conn, ~p"/forges")

      assert index_live |> element("#forges-#{connection.id} a", "Edit") |> render_click() =~
               "Edit Connection"

      assert_patch(index_live, ~p"/forges/#{connection}/edit")

      assert index_live
             |> form("#connection-form", connection: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#connection-form", connection: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/forges")

      html = render(index_live)
      assert html =~ "Connection updated successfully"
      assert html =~ "some updated name"
    end

    test "deletes connection in listing", %{conn: conn, connection: connection} do
      {:ok, index_live, _html} = live(conn, ~p"/forges")

      assert index_live |> element("#forges-#{connection.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#forges-#{connection.id}")
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_connection]

    test "displays connection", %{conn: conn, connection: connection} do
      {:ok, _show_live, html} = live(conn, ~p"/forges/#{connection}")

      assert html =~ "Show Connection"
      assert html =~ connection.name
    end

    test "updates connection within modal", %{conn: conn, connection: connection} do
      {:ok, show_live, _html} = live(conn, ~p"/forges/#{connection}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Connection"

      assert_patch(show_live, ~p"/forges/#{connection}/show/edit")

      assert show_live
             |> form("#connection-form", connection: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#connection-form", connection: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/forges/#{connection}")

      html = render(show_live)
      assert html =~ "Connection updated successfully"
      assert html =~ "some updated name"
    end
  end
end
