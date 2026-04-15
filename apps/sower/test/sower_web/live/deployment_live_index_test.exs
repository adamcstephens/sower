defmodule SowerWeb.DeploymentLive.IndexTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Sower.OrchestrationFixtures

  setup [:register_and_log_in_user]

  test "shows retry button only for terminal deployments", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    retryable =
      deployment_fixture(%{
        garden_id: garden.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    not_retryable =
      deployment_fixture(%{
        garden_id: garden.id,
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
    garden = garden_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: :failure,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    {:ok, index_live, _html} = live(conn, ~p"/deployments")
    index_live |> element("button[phx-value-sid='#{deployment.sid}']", "Retry") |> render_click()

    assert render(index_live) =~ "Retry deployment created"

    retried =
      Sower.Repo.get_by!(Sower.Orchestration.Deployment, parent_deployment_id: deployment.id)

    retried = Sower.Repo.preload(retried, :events)
    assert [event] = retried.events
    assert event.event == :created
    assert event.reason == :user_retry
    assert event.actor_sid == user.sid
  end

  test "shows error when retry submission fails", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    deployment_fixture(%{
      garden_id: garden.id,
      parent_deployment_id: deployment.id,
      retry_ordinal: 1
    })

    {:ok, index_live, _html} = live(conn, ~p"/deployments")

    html =
      index_live
      |> element("button[phx-value-sid='#{deployment.sid}']", "Retry")
      |> render_click()

    assert html =~ "A retry is already in progress for this deployment"
  end
end
