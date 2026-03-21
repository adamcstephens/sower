defmodule SowerWeb.GardenLive.ShowTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  defp create_garden_with_subscription(user, seed_attrs \\ %{}) do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    seed = seed_fixture(seed_attrs)

    subscription =
      subscription_fixture(%{
        garden_id: garden.id,
        seed_name: seed.name,
        seed_type: seed.seed_type
      })

    %{garden: garden, subscription: subscription, seed: seed}
  end

  test "shows deploy button when subscription has matching seed", %{conn: conn, user: user} do
    %{garden: garden} = create_garden_with_subscription(user)

    {:ok, show_live, _html} = live(conn, ~p"/gardens/#{garden}")

    assert has_element?(show_live, "button", "Deploy")
  end

  test "does not show deploy button when subscription has no matching seed", %{
    conn: conn,
    user: user
  } do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    subscription_fixture(%{
      garden_id: garden.id,
      seed_name: "nonexistent-seed",
      seed_type: "nixos"
    })

    {:ok, show_live, _html} = live(conn, ~p"/gardens/#{garden}")

    refute has_element?(show_live, "button", "Deploy")
  end

  test "clicking deploy triggers deployment and redirects", %{conn: conn, user: user} do
    %{garden: garden, subscription: subscription} = create_garden_with_subscription(user)

    {:ok, show_live, _html} = live(conn, ~p"/gardens/#{garden}")

    show_live
    |> element("button[phx-value-subscription_sid=\"#{subscription.sid}\"]", "Deploy")
    |> render_click()

    # The deployment is async - wait for PubSub broadcast to trigger redirect
    deployment =
      eventually(fn ->
        [d | _] = Sower.Orchestration.list_deployments(garden, limit: 1)
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
