defmodule SowerWeb.SubscriptionLive.ShowTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  defp create_subscription_with_seed(user) do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    %{garden: garden, subscription: subscription, seed: seed}
  end

  test "shows deploy button when subscription matches latest seed", %{conn: conn, user: user} do
    %{garden: garden, subscription: subscription} = create_subscription_with_seed(user)

    {:ok, show_live, _html} =
      live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}")

    assert has_element?(show_live, "button", "Deploy")
  end

  test "does not show deploy button when no matching seed", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "nonexistent-seed",
        seed_type: "nixos"
      })

    {:ok, show_live, _html} =
      live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}")

    refute has_element?(show_live, "button", "Deploy")
  end

  test "clicking deploy triggers deployment and redirects", %{conn: conn, user: user} do
    %{garden: garden, subscription: subscription} = create_subscription_with_seed(user)

    {:ok, show_live, _html} =
      live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}")

    show_live
    |> element(~s{button[phx-click="deploy_subscription"]}, "Deploy")
    |> render_click()

    deployment =
      eventually(fn ->
        [d | _] = Sower.Orchestration.list_deployments(garden, limit: 1)
        d
      end)

    assert_redirect(show_live, ~p"/deployments/#{deployment.sid}")
  end

  test "clicking a seed row deploy triggers deployment of that seed", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    older = seed_fixture(%{name: "rowhost", seed_type: "nixos"})

    Process.sleep(10)

    _newer = seed_fixture(%{name: "rowhost", seed_type: "nixos"})

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: "rowhost",
        seed_type: "nixos"
      })

    {:ok, show_live, _html} =
      live(conn, ~p"/gardens/#{garden}/subscriptions/#{subscription}")

    show_live
    |> element(~s{#subscription-seeds button[phx-value-seed_sid="#{older.sid}"]})
    |> render_click()

    deployment =
      eventually(fn ->
        [d | _] = Sower.Orchestration.list_deployments(garden, limit: 1)
        d
      end)

    deployment = Sower.Repo.preload(deployment, :seeds)
    assert Enum.map(deployment.seeds, & &1.sid) == [older.sid]

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
