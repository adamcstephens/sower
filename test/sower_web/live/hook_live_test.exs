defmodule SowerWeb.HookLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.ForgeFixtures

  @create_attrs %{request: %{}}
  @update_attrs %{request: %{}}
  @invalid_attrs %{request: nil}

  defp create_hook(_) do
    hook = hook_fixture()
    %{hook: hook}
  end

  describe "Index" do
    setup [:create_hook]

    test "lists all hooks", %{conn: conn} do
      {:ok, _index_live, html} = live(conn, ~p"/hooks")

      assert html =~ "Listing Hooks"
    end

    test "saves new hook", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/hooks")

      assert index_live |> element("a", "New Hook") |> render_click() =~
               "New Hook"

      assert_patch(index_live, ~p"/hooks/new")

      assert index_live
             |> form("#hook-form", hook: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#hook-form", hook: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/hooks")

      html = render(index_live)
      assert html =~ "Hook created successfully"
    end

    test "updates hook in listing", %{conn: conn, hook: hook} do
      {:ok, index_live, _html} = live(conn, ~p"/hooks")

      assert index_live |> element("#hooks-#{hook.id} a", "Edit") |> render_click() =~
               "Edit Hook"

      assert_patch(index_live, ~p"/hooks/#{hook}/edit")

      assert index_live
             |> form("#hook-form", hook: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#hook-form", hook: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/hooks")

      html = render(index_live)
      assert html =~ "Hook updated successfully"
    end

    test "deletes hook in listing", %{conn: conn, hook: hook} do
      {:ok, index_live, _html} = live(conn, ~p"/hooks")

      assert index_live |> element("#hooks-#{hook.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#hooks-#{hook.id}")
    end
  end

  describe "Show" do
    setup [:create_hook]

    test "displays hook", %{conn: conn, hook: hook} do
      {:ok, _show_live, html} = live(conn, ~p"/hooks/#{hook}")

      assert html =~ "Show Hook"
    end

    test "updates hook within modal", %{conn: conn, hook: hook} do
      {:ok, show_live, _html} = live(conn, ~p"/hooks/#{hook}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Hook"

      assert_patch(show_live, ~p"/hooks/#{hook}/show/edit")

      assert show_live
             |> form("#hook-form", hook: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#hook-form", hook: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/hooks/#{hook}")

      html = render(show_live)
      assert html =~ "Hook updated successfully"
    end
  end
end
