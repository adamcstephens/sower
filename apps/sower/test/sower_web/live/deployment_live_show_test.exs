defmodule SowerWeb.DeploymentLive.ShowTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Changeset

  alias Sower.Orchestration.DeploymentPubSub
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  test "renders seed deployment logs and toggles inline log panel", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)

    garden = garden_fixture()
    seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: []
      })

    # Write a log to the seed_deployment
    seed_deployment =
      Sower.Repo.get_by!(
        Sower.Orchestration.SeedDeployment,
        [deployment_id: deployment.id, seed_id: seed.id],
        skip_org_id: true
      )

    seed_deployment
    |> Ecto.Changeset.change(%{log: "test log output", result: :success})
    |> Sower.Repo.update!(skip_org_id: true)

    {:ok, show_live, html} = live(conn, ~p"/deployments/#{deployment.sid}")

    assert html =~ "Seeds"
    assert html =~ "#{seed.seed_type}/#{seed.name}"
    assert html =~ seed.artifact
    assert has_element?(show_live, "#seed-log-#{seed.sid} button", "View log")

    assert show_live |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()

    assert has_element?(show_live, "#seed-log-content-#{seed.sid}")
    assert render(show_live) =~ "test log output"

    assert show_live |> element("#seed-log-#{seed.sid} button", "Hide log") |> render_click()
    refute has_element?(show_live, "#seed-log-content-#{seed.sid}")
  end

  test "shows empty state when deployment has no seeds", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)

    garden = garden_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [],
        subscriptions: []
      })

    {:ok, _show_live, html} = live(conn, ~p"/deployments/#{deployment.sid}")

    assert html =~ "Seeds"
    assert html =~ "No seeds."
  end

  test "subscribes to per-deployment topic on mount", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    current_deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: nil,
        state: :dispatched,
        deployed_at: nil
      })

    other_deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: nil,
        state: :dispatched,
        deployed_at: nil
      })

    {:ok, show_live, _html} = live(conn, ~p"/deployments/#{current_deployment.sid}")
    refute has_element?(show_live, "button", "Retry")

    other_deployment
    |> change(%{result: :success, deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Sower.Repo.update!()

    assert {:ok, _deployment} =
             DeploymentPubSub.broadcast_deployment_change(other_deployment, :updated)

    refute has_element?(show_live, "button", "Retry")
  end

  test "refreshes deployment when update is broadcast", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: nil,
        state: :dispatched,
        deployed_at: nil
      })

    {:ok, show_live, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    refute has_element?(show_live, "button", "Retry")

    deployment
    |> change(%{
      result: :success,
      state: :completed,
      deployed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Sower.Repo.update!()

    assert {:ok, _deployment} = DeploymentPubSub.broadcast_deployment_change(deployment, :updated)

    assert has_element?(show_live, "button", "Retry")
  end

  test "cleans up PubSub subscription on LiveView termination", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: nil,
        state: :dispatched,
        deployed_at: nil
      })

    {:ok, show_live, _html} = live(conn, ~p"/deployments/#{deployment.sid}")

    topic = "deployment:#{deployment.sid}"

    assert Enum.any?(Registry.lookup(Sower.PubSub, topic), fn {pid, _} ->
             pid == show_live.pid
           end)

    monitor_ref = Process.monitor(show_live.pid)
    GenServer.stop(show_live.pid)

    assert_receive {:DOWN, ^monitor_ref, :process, _pid, _reason}

    # Registry cleanup is async; wait for unregistration
    :ok =
      Enum.reduce_while(1..50, :error, fn _, _ ->
        if Enum.any?(Registry.lookup(Sower.PubSub, topic), fn {pid, _} ->
             pid == show_live.pid
           end) do
          Process.sleep(10)
          {:cont, :error}
        else
          {:halt, :ok}
        end
      end)

    refute Enum.any?(Registry.lookup(Sower.PubSub, topic), fn {pid, _} ->
             pid == show_live.pid
           end)
  end

  test "shows retry button only for terminal deployments", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    successful_deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    running_deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: nil,
        state: :dispatched,
        deployed_at: nil
      })

    {:ok, _show_live, html} = live(conn, ~p"/deployments/#{successful_deployment.sid}")
    assert html =~ "Retry"
    refute html =~ "hero-arrow-left"

    {:ok, _show_live, html} = live(conn, ~p"/deployments/#{running_deployment.sid}")
    refute html =~ "Retry"
    refute html =~ "hero-arrow-left"
  end

  test "creates a retry deployment from the show page", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    {:ok, show_live, _html} = live(conn, ~p"/deployments/#{deployment.sid}")

    show_live |> element("button", "Retry") |> render_click()

    retried =
      Sower.Repo.get_by!(Sower.Orchestration.Deployment, parent_deployment_id: deployment.id)

    retried = Sower.Repo.preload(retried, :events)
    assert [event] = retried.events
    assert event.event == :created
    assert event.reason == :retry
    assert event.actor_sid == user.sid

    assert_redirect(show_live, ~p"/deployments/#{retried.sid}")
  end

  test "displays seed deployment state", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [],
        state: :acknowledged,
        result: nil,
        deployed_at: nil
      })

    seed_deployment =
      Sower.Repo.get_by!(
        Sower.Orchestration.SeedDeployment,
        [deployment_id: deployment.id, seed_id: seed.id],
        skip_org_id: true
      )

    seed_deployment
    |> change(%{state: :downloading})
    |> Sower.Repo.update!(skip_org_id: true)

    {:ok, _show_live, html} = live(conn, ~p"/deployments/#{deployment.sid}")

    assert html =~ "Downloading"
  end

  test "updates seed deployment state via PubSub broadcast", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed],
        subscriptions: [],
        state: :acknowledged,
        result: nil,
        deployed_at: nil
      })

    {:ok, show_live, html} = live(conn, ~p"/deployments/#{deployment.sid}")

    assert html =~ "Pending"

    # Update seed deployment state in DB
    seed_deployment =
      Sower.Repo.get_by!(
        Sower.Orchestration.SeedDeployment,
        [deployment_id: deployment.id, seed_id: seed.id],
        skip_org_id: true
      )

    seed_deployment
    |> change(%{state: :activating})
    |> Sower.Repo.update!(skip_org_id: true)

    # Broadcast seed status change
    Phoenix.PubSub.broadcast!(
      Sower.PubSub,
      "deployment:#{deployment.sid}",
      {:seed_deployment, :updated}
    )

    assert render(show_live) =~ "Activating"
  end

  test "shows error when retry is already in progress", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()

    parent =
      deployment_fixture(%{
        garden_id: garden.id,
        result: :success,
        state: :completed,
        deployed_at: DateTime.utc_now()
      })

    deployment_fixture(%{
      garden_id: garden.id,
      parent_deployment_id: parent.id,
      retry_ordinal: 1
    })

    {:ok, show_live, _html} = live(conn, ~p"/deployments/#{parent.sid}")

    assert show_live |> element("button", "Retry") |> render_click() =~
             "A retry is already in progress for this deployment"
  end
end
