defmodule SowerWeb.DeploymentLive.ShowTest do
  use SowerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Changeset

  alias Sower.Orchestration.DeploymentLog
  alias Sower.Orchestration.DeploymentPubSub
  import Sower.OrchestrationFixtures
  import Sower.SeedFixtures

  setup [:register_and_log_in_user]

  test "loads running history, appends ordered live chunks and switches to final logs", %{
    conn: conn,
    user: user
  } do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()
    other_seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed, other_seed],
        subscriptions: [],
        state: :acknowledged,
        result: nil,
        deployed_at: nil
      })

    start_log_buffer(deployment)

    ingest = &ingest(deployment, garden, &1, &2, &3)

    assert {:ok, _} = ingest.(seed, 1, "realizing\n")
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    view |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()
    assert element(view, "#seed-log-content-#{seed.sid}") |> render() =~ "realizing"

    assert {:ok, _} = ingest.(seed, 3, "activated\n")
    assert {:ok, _} = ingest.(seed, 3, "duplicate must not appear\n")
    assert {:ok, _} = ingest.(other_seed, 1, "other seed output\n")
    html = element(view, "#seed-log-content-#{seed.sid}") |> render()
    assert html =~ "realizing"
    assert html =~ "activated"
    assert has_element?(view, "#deployment-log-history-notice")
    refute html =~ "duplicate"
    refute html =~ "other seed output"

    assert {:ok, _} = ingest.(seed, 2, "activating\n")
    html = element(view, "#seed-log-content-#{seed.sid}") |> render()
    assert html =~ "realizing\nactivating\nactivated"
    refute has_element?(view, "#deployment-log-history-notice")

    replayed_first =
      deployment
      |> DeploymentLog.list()
      |> Enum.find(&(&1.seed_sid == seed.sid and &1.sequence == 1))

    send(view.pid, {:seed_deployment_log, %{replayed_first | reset?: true}})

    assert element(view, "#seed-log-content-#{seed.sid}") |> render() =~
             "realizing\nactivating\nactivated"

    refute has_element?(view, "#deployment-log-history-notice")

    GenServer.stop(view.pid)
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    view |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()

    assert element(view, "#seed-log-content-#{seed.sid}") |> render() =~
             "realizing\nactivating\nactivated"

    [late_chunk | _] = DeploymentLog.list(deployment)

    seed_deployment =
      Sower.Repo.get_by!(
        Sower.Orchestration.SeedDeployment,
        [deployment_id: deployment.id, seed_id: seed.id],
        skip_org_id: true
      )

    seed_deployment
    |> change(%{result: :success, log: "authoritative final output"})
    |> Sower.Repo.update!(skip_org_id: true)

    deployment =
      deployment
      |> change(%{state: :completed, result: :success})
      |> Sower.Repo.update!()

    DeploymentPubSub.broadcast_deployment_change(deployment, :updated)
    html = element(view, "#seed-log-content-#{seed.sid}") |> render()
    assert html =~ "authoritative final output"
    refute html =~ "realizing"

    DeploymentPubSub.broadcast_seed_deployment_log(%{
      late_chunk
      | seed_sid: other_seed.sid,
        sequence: 2,
        output: "late non-authoritative output",
        reset?: true,
        evicted: []
    })

    html = element(view, "#seed-log-content-#{seed.sid}") |> render()
    assert html =~ "authoritative final output"
    refute html =~ "late non-authoritative output"
    refute has_element?(view, "#deployment-log-history-notice")
    refute has_element?(view, "#seed-log-#{other_seed.sid} button")
  end

  test "evicts rendered output without losing retained or unrelated seed chunks and reconnects",
       %{
         conn: conn,
         user: user
       } do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()
    other_seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed, other_seed],
        subscriptions: [],
        state: :acknowledged,
        result: nil,
        deployed_at: nil
      })

    start_log_buffer(deployment, 3)
    assert {:ok, _} = ingest(deployment, garden, seed, 1, "old output\n")
    assert {:ok, _} = ingest(deployment, garden, other_seed, 1, "unrelated output\n")
    assert {:ok, _} = ingest(deployment, garden, seed, 2, "retained output\n")

    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    view |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()
    view |> element("#seed-log-#{other_seed.sid} button", "View log") |> render_click()
    assert element(view, "#seed-log-content-#{seed.sid}") |> render() =~ "old output"

    assert {:ok, _} = ingest(deployment, garden, seed, 3, "latest output\n")
    html = element(view, "#seed-log-content-#{seed.sid}") |> render()
    refute html =~ "old output"
    assert html =~ "retained output\nlatest output"
    assert element(view, "#seed-log-content-#{other_seed.sid}") |> render() =~ "unrelated output"
    assert has_element?(view, "#deployment-log-history-notice")

    GenServer.stop(view.pid)
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    view |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()
    view |> element("#seed-log-#{other_seed.sid} button", "View log") |> render_click()
    html = element(view, "#seed-log-content-#{seed.sid}") |> render()
    refute html =~ "old output"
    assert html =~ "retained output\nlatest output"
    assert element(view, "#seed-log-content-#{other_seed.sid}") |> render() =~ "unrelated output"
    assert has_element?(view, "#deployment-log-history-notice")
  end

  test "a new owner clears all previous live history", %{conn: conn, user: user} do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()
    other_seed = seed_fixture()

    deployment =
      deployment_fixture(%{
        garden_id: garden.id,
        seeds: [seed, other_seed],
        subscriptions: [],
        state: :acknowledged,
        result: nil,
        deployed_at: nil
      })

    pool = start_log_buffer(deployment)
    assert {:ok, _} = ingest(deployment, garden, seed, 1, "old owner output\n")
    assert {:ok, _} = ingest(deployment, garden, other_seed, 1, "old unrelated output\n")
    [stale_chunk | _] = DeploymentLog.list(deployment)

    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    view |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()
    view |> element("#seed-log-#{other_seed.sid} button", "View log") |> render_click()
    assert render(view) =~ "old owner output"
    assert render(view) =~ "old unrelated output"

    assert :ok = DeploymentLog.Pool.delete(deployment)
    assert {:ok, _} = DeploymentLog.Pool.ensure(Sower.Repo.preload(deployment, :seeds), pool)
    assert {:ok, _} = ingest(deployment, garden, seed, 2, "new owner output\n")

    html = render(view)
    assert html =~ "new owner output"
    refute html =~ "old owner output"
    refute html =~ "old unrelated output"
    refute has_element?(view, "#seed-log-content-#{other_seed.sid}")
    assert has_element?(view, "#deployment-log-history-notice")

    send(
      view.pid,
      {:seed_deployment_log, %{stale_chunk | sequence: 99, output: "stale owner event"}}
    )

    html = render(view)
    assert html =~ "new owner output"
    refute html =~ "stale owner event"
  end

  test "does not restore output that was immediately evicted from the buffer", %{
    conn: conn,
    user: user
  } do
    Sower.Repo.put_org_id(user.org_id)
    garden = garden_fixture()
    seed = seed_fixture()

    deployment =
      deployment_fixture(%{garden_id: garden.id, seeds: [seed], state: :acknowledged})

    start_log_buffer(deployment, 1024, 3)
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.sid}")
    assert {:ok, _} = ingest(deployment, garden, seed, 1, "ab")
    view |> element("#seed-log-#{seed.sid} button", "View log") |> render_click()
    assert element(view, "#seed-log-content-#{seed.sid}") |> render() =~ "ab"

    assert {:ok, _} = ingest(deployment, garden, seed, 2, "oversized output")
    refute has_element?(view, "#seed-log-content-#{seed.sid}")
    refute render(view) =~ "oversized output"
    assert has_element?(view, "#deployment-log-history-notice")
  end

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
    assert event.reason == :user_retry
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

  defp start_log_buffer(
         %Sower.Orchestration.Deployment{} = deployment,
         max_chunks \\ 1024,
         max_bytes \\ 1_048_576
       ) do
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    pool =
      start_supervised!(
        {DeploymentLog.Pool,
         name: nil,
         supervisor: supervisor,
         max_buffers: 4,
         max_chunks: max_chunks,
         max_bytes: max_bytes}
      )

    assert {:ok, _} = DeploymentLog.Pool.ensure(Sower.Repo.preload(deployment, :seeds), pool)
    pool
  end

  defp ingest(
         %Sower.Orchestration.Deployment{} = deployment,
         %Sower.Orchestration.Garden{} = garden,
         %Sower.Orchestration.Seed{} = seed,
         sequence,
         output
       ) do
    DeploymentLog.record(
      %SowerClient.Orchestration.SeedDeploymentLog{
        deployment_sid: deployment.sid,
        seed_sid: seed.sid,
        sequence: sequence,
        output: output
      },
      garden
    )
  end
end
