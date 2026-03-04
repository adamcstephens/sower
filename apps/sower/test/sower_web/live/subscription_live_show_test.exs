defmodule SowerWeb.SubscriptionLive.ShowTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  defp create_subscription_with_seed(user) do
    Sower.Repo.put_org_id(user.org_id)
    agent = agent_fixture()
    seed = seed_fixture()

    subscription =
      subscription_fixture(%{
        agent_id: agent.id,
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    %{agent: agent, subscription: subscription, seed: seed}
  end

  test "shows deploy button when subscription matches latest seed", %{conn: conn, user: user} do
    %{agent: agent, subscription: subscription} = create_subscription_with_seed(user)

    {:ok, show_live, _html} =
      live(conn, ~p"/agents/#{agent}/subscriptions/#{subscription}")

    assert has_element?(show_live, "button", "Deploy")
  end

  test "does not show deploy button when no matching seed", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    agent = agent_fixture()

    subscription =
      subscription_fixture(%{
        agent_id: agent.id,
        seed_name: "nonexistent-seed",
        seed_type: "nixos"
      })

    {:ok, show_live, _html} =
      live(conn, ~p"/agents/#{agent}/subscriptions/#{subscription}")

    refute has_element?(show_live, "button", "Deploy")
  end

  test "clicking deploy triggers deployment and redirects", %{conn: conn, user: user} do
    %{agent: agent, subscription: subscription} = create_subscription_with_seed(user)

    {:ok, show_live, _html} =
      live(conn, ~p"/agents/#{agent}/subscriptions/#{subscription}")

    show_live
    |> element("button", "Deploy")
    |> render_click()

    deployment =
      eventually(fn ->
        [d | _] = Sower.Orchestration.list_deployments(agent, limit: 1)
        d
      end)

    assert_redirect(show_live, ~p"/deployments/#{deployment.sid}")
  end

  defp eventually(fun, retries \\ 20) do
    fun.()
  rescue
    _ ->
      if retries > 0 do
        Process.sleep(50)
        eventually(fun, retries - 1)
      else
        raise "eventually timed out"
      end
  catch
    _ ->
      if retries > 0 do
        Process.sleep(50)
        eventually(fun, retries - 1)
      else
        raise "eventually timed out"
      end
  end
end
