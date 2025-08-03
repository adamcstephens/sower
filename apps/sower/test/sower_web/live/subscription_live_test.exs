defmodule SowerWeb.SubscriptionLiveTest do
  use SowerWeb.ConnCase

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  defp create_subscription(%{user: %{org_id: org_id}}) do
    agent = agent_fixture(%{org_id: org_id})
    seed = seed_fixture()
    subscription = subscription_fixture(%{org_id: org_id, agent_id: agent.id, seed_id: seed.id})
    %{subscription: subscription}
  end

  describe "Index" do
    setup [:register_and_log_in_user, :create_subscription]

    test "lists all subscriptions", %{conn: conn, subscription: subscription} do
      {:ok, _index_live, html} = live(conn, ~p"/subscriptions")

      assert html =~ "Listing Subscriptions"
      assert html =~ subscription.sid
    end
  end

  describe "Show" do
    setup [:register_and_log_in_user, :create_subscription]

    test "displays subscription", %{conn: conn, subscription: subscription} do
      {:ok, _show_live, html} = live(conn, ~p"/subscriptions/#{subscription}")

      assert html =~ "Show Subscription"
      assert html =~ subscription.sid
    end
  end
end
