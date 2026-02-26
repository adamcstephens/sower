defmodule SowerWeb.DeploymentLive.ShowTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  test "renders seed deployment logs and toggles inline log panel", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)

    agent = agent_fixture()
    seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        agent_id: agent.id,
        seeds: [seed],
        subscriptions: []
      })

    {:ok, show_live, html} = live(conn, ~p"/deployments/#{deployment.sid}")

    assert html =~ "Seeds"
    assert html =~ "#{seed.seed_type}/#{seed.name}"
    assert html =~ seed.artifact
    assert has_element?(show_live, "#seed-log-#{seed.sid} button", "View log")

    assert show_live |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()

    log_url = ~p"/deployments/#{deployment.sid}/seeds/#{seed.sid}/log"
    assert has_element?(show_live, "#seed-log-#{seed.sid} iframe[src=\"#{log_url}\"]")
    refute has_element?(show_live, "#seed-log-frame-#{seed.sid}.hidden")

    assert has_element?(
             show_live,
             "#seed-log-#{seed.sid} a[href=\"#{log_url}\"]",
             "Open in new tab"
           )

    assert show_live |> element("#seed-log-#{seed.sid} button", "Hide log") |> render_click()
    assert has_element?(show_live, "#seed-log-#{seed.sid} iframe[src=\"#{log_url}\"]")
    assert has_element?(show_live, "#seed-log-frame-#{seed.sid}.hidden")
  end

  test "shows empty logs state when deployment has no seeds", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)

    agent = agent_fixture()

    deployment =
      deployment_fixture(%{
        agent_id: agent.id,
        seeds: [],
        subscriptions: []
      })

    {:ok, _show_live, html} = live(conn, ~p"/deployments/#{deployment.sid}")

    assert html =~ "Seeds"
    assert html =~ "No seeds."
  end
end
