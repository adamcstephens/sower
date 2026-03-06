defmodule SowerWeb.DeploymentLive.IndexTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  setup [:register_and_log_in_user]

  test "shows retry button only for terminal deployments", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    agent = agent_fixture()

    retryable =
      deployment_fixture(%{
        agent_id: agent.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    not_retryable =
      deployment_fixture(%{
        agent_id: agent.id,
        result: nil,
        state: :dispatched,
        deployed_at: nil
      })

    {:ok, index_live, _html} = live(conn, ~p"/deployments")

    assert has_element?(index_live, "button[phx-value-sid='#{retryable.sid}']", "Retry")
    refute has_element?(index_live, "button[phx-value-sid='#{not_retryable.sid}']", "Retry")
  end

  test "creates retry deployment from index retry button", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    agent = agent_fixture()

    deployment =
      deployment_fixture(%{
        agent_id: agent.id,
        result: :failure,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    {:ok, index_live, _html} = live(conn, ~p"/deployments")
    index_live |> element("button[phx-value-sid='#{deployment.sid}']", "Retry") |> render_click()

    assert render(index_live) =~ "Retry deployment created"

    retried =
      Sower.Repo.get_by!(Sower.Orchestration.Deployment, parent_deployment_id: deployment.id)

    assert retried.retried_by_user_id == user.id
  end

  test "shows error when retry submission fails", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    agent = agent_fixture()

    deployment =
      deployment_fixture(%{
        agent_id: agent.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    deployment_fixture(%{
      agent_id: agent.id,
      parent_deployment_id: deployment.id,
      retry_ordinal: 1,
      retried_by_user_id: user.id,
      retried_at: DateTime.utc_now()
    })

    {:ok, index_live, _html} = live(conn, ~p"/deployments")

    html =
      index_live
      |> element("button[phx-value-sid='#{deployment.sid}']", "Retry")
      |> render_click()

    assert html =~ "A retry is already in progress for this deployment"
  end
end
