defmodule SowerWeb.Settings.AccessTokenLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.AccountsFixtures

  @create_attrs %{
    description: "test"
  }
  @update_attrs %{
    description: "second",
    regenerate: true
  }
  @invalid_attrs %{
    description: ""
  }

  defp create_access_token(context) do
    access_token = access_token_fixture(%{"user_id" => context.user.id})
    %{access_token: access_token}
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_access_token]

    test "lists all access-tokens", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/settings/access-tokens")

      assert html =~ "Listing Access-tokens"
    end

    test "saves new access_token", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/settings/access-tokens")

      assert index_live |> element("a", "New Token") |> render_click() =~
               "New Token"

      assert_patch(index_live, ~p"/settings/access-tokens/new")

      assert index_live
             |> form("#access_token-form", access_token: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#access_token-form", access_token: @create_attrs)
             |> render_submit()

      assert_redirect(index_live)
    end

    test "updates access_token in listing", %{conn: conn, access_token: access_token} do
      {:ok, index_live, _html} = live(conn, ~p"/settings/access-tokens")

      assert index_live
             |> element("#access_tokens-#{access_token.id} a", "Edit")
             |> render_click() =~ "Edit"

      assert_patch(index_live, ~p"/settings/access-tokens/#{access_token}/edit")

      assert index_live
             |> form("#access_token-form", access_token: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#access_token-form", access_token: @update_attrs)
             |> render_submit()

      assert_patch(index_live)
    end

    test "deletes access_token in listing", %{conn: conn, access_token: access_token} do
      {:ok, index_live, _html} = live(conn, ~p"/settings/access-tokens")

      assert index_live
             |> element("#access_tokens-#{access_token.id} a", "Delete")
             |> render_click()

      refute has_element?(index_live, "#access_tokens-#{access_token.id}")
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_access_token]

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
      assert html =~ "Copy this token now! It will not be stored nor shown again."
    end

    test "deletes access_token within model", %{conn: conn, access_token: access_token} do
      {:ok, show_live, _html} = live(conn, ~p"/settings/access-tokens/#{access_token}")

      assert show_live
             |> element("a", "Delete")
             |> render_click()

      assert_redirect(show_live)
    end
  end
end
