defmodule SowerWeb.Settings.AccessTokenLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.AccountsFixtures

  @create_attrs %{}
  @update_attrs %{}
  @invalid_attrs %{}

  defp create_access_token(_) do
    access_token = access_token_fixture()
    %{access_token: access_token}
  end

  describe "Index" do
    setup [:create_access_token]

    test "lists all access-tokens", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/settings/access-tokens")

      assert html =~ "Listing Access-tokens"
    end

    test "saves new access_token", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/settings/access-tokens")

      assert index_live |> element("a", "New Access token") |> render_click() =~
               "New Access token"

      assert_patch(index_live, ~p"/settings/access-tokens/new")

      assert index_live
             |> form("#access_token-form", access_token: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#access_token-form", access_token: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/settings/access-tokens")

      html = render(index_live)
      assert html =~ "Access token created successfully"
    end

    test "updates access_token in listing", %{conn: conn, access_token: access_token} do
      {:ok, index_live, _html} = live(conn, ~p"/settings/access-tokens")

      assert index_live |> element("#access-tokens-#{access_token.id} a", "Edit") |> render_click() =~
               "Edit Access token"

      assert_patch(index_live, ~p"/settings/access-tokens/#{access_token}/edit")

      assert index_live
             |> form("#access_token-form", access_token: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#access_token-form", access_token: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/settings/access-tokens")

      html = render(index_live)
      assert html =~ "Access token updated successfully"
    end

    test "deletes access_token in listing", %{conn: conn, access_token: access_token} do
      {:ok, index_live, _html} = live(conn, ~p"/settings/access-tokens")

      assert index_live |> element("#access-tokens-#{access_token.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#access-tokens-#{access_token.id}")
    end
  end

  describe "Show" do
    setup [:create_access_token]

    test "displays access_token", %{conn: conn, access_token: access_token} do
      {:ok, _show_live, html} = live(conn, ~p"/settings/access-tokens/#{access_token}")

      assert html =~ "Show Access token"
    end

    test "updates access_token within modal", %{conn: conn, access_token: access_token} do
      {:ok, show_live, _html} = live(conn, ~p"/settings/access-tokens/#{access_token}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Access token"

      assert_patch(show_live, ~p"/settings/access-tokens/#{access_token}/show/edit")

      assert show_live
             |> form("#access_token-form", access_token: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#access_token-form", access_token: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/settings/access-tokens/#{access_token}")

      html = render(show_live)
      assert html =~ "Access token updated successfully"
    end
  end
end
