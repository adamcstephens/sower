defmodule SowerWeb.SubscriptionLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  @create_attrs %{sid: "some sid"}
  @update_attrs %{sid: "some updated sid"}
  @invalid_attrs %{sid: nil}

  defp create_subscription(_) do
    subscription = subscription_fixture()
    %{subscription: subscription}
  end

  describe "Index" do
    setup [:create_subscription]

    test "lists all subscriptions", %{conn: conn, subscription: subscription} do
      {:ok, _index_live, html} = live(conn, ~p"/subscriptions")

      assert html =~ "Listing Subscriptions"
      assert html =~ subscription.sid
    end

    test "saves new subscription", %{conn: conn} do
      {:ok, index_live, _html} = live(conn, ~p"/subscriptions")

      assert index_live |> element("a", "New Subscription") |> render_click() =~
               "New Subscription"

      assert_patch(index_live, ~p"/subscriptions/new")

      assert index_live
             |> form("#subscription-form", subscription: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#subscription-form", subscription: @create_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/subscriptions")

      html = render(index_live)
      assert html =~ "Subscription created successfully"
      assert html =~ "some sid"
    end

    test "updates subscription in listing", %{conn: conn, subscription: subscription} do
      {:ok, index_live, _html} = live(conn, ~p"/subscriptions")

      assert index_live |> element("#subscriptions-#{subscription.id} a", "Edit") |> render_click() =~
               "Edit Subscription"

      assert_patch(index_live, ~p"/subscriptions/#{subscription}/edit")

      assert index_live
             |> form("#subscription-form", subscription: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert index_live
             |> form("#subscription-form", subscription: @update_attrs)
             |> render_submit()

      assert_patch(index_live, ~p"/subscriptions")

      html = render(index_live)
      assert html =~ "Subscription updated successfully"
      assert html =~ "some updated sid"
    end

    test "deletes subscription in listing", %{conn: conn, subscription: subscription} do
      {:ok, index_live, _html} = live(conn, ~p"/subscriptions")

      assert index_live |> element("#subscriptions-#{subscription.id} a", "Delete") |> render_click()
      refute has_element?(index_live, "#subscriptions-#{subscription.id}")
    end
  end

  describe "Show" do
    setup [:create_subscription]

    test "displays subscription", %{conn: conn, subscription: subscription} do
      {:ok, _show_live, html} = live(conn, ~p"/subscriptions/#{subscription}")

      assert html =~ "Show Subscription"
      assert html =~ subscription.sid
    end

    test "updates subscription within modal", %{conn: conn, subscription: subscription} do
      {:ok, show_live, _html} = live(conn, ~p"/subscriptions/#{subscription}")

      assert show_live |> element("a", "Edit") |> render_click() =~
               "Edit Subscription"

      assert_patch(show_live, ~p"/subscriptions/#{subscription}/show/edit")

      assert show_live
             |> form("#subscription-form", subscription: @invalid_attrs)
             |> render_change() =~ "can&#39;t be blank"

      assert show_live
             |> form("#subscription-form", subscription: @update_attrs)
             |> render_submit()

      assert_patch(show_live, ~p"/subscriptions/#{subscription}")

      html = render(show_live)
      assert html =~ "Subscription updated successfully"
      assert html =~ "some updated sid"
    end
  end
end
